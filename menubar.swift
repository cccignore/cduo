// Cduo 菜单栏 App（SwiftUI 弹出面板）：多个 Claude 号的额度、一键切换、全部设置。
// 构建：build_app.sh
import Cocoa
import SwiftUI
import UserNotifications

let home = NSHomeDirectory()
let cduoDir = home + "/.cduo"
let cduoBin: String = {
    if let e = ProcessInfo.processInfo.environment["CDUO_BIN"] { return e }
    let installed = home + "/.cduo/app/cduo"
    if FileManager.default.fileExists(atPath: installed) { return installed }
    return (Bundle.main.resourcePath ?? "") + "/cduo"
}()
let procEnv = ProcessInfo.processInfo.environment
let dumpMode = procEnv["CDUO_MENUBAR_DUMP"] == "1"
let previewDir = procEnv["CDUO_PREVIEW_DIR"]
let panelWidth: CGFloat = 348
let cardsScrollHeight: CGFloat = 460   // 超过 4 个号时卡片区域的高度：两行多一点，看得出下面还有

// MARK: - 工具

func hhmm(_ ts: Double?) -> String {
    guard let ts = ts else { return "--:--" }
    let d = Date(timeIntervalSince1970: ts)
    let f = DateFormatter()
    f.dateFormat = Calendar.current.isDateInToday(d) ? "HH:mm" : "明天 HH:mm"
    return f.string(from: d)
}

func runCduo(_ args: [String], completion: ((String, Int32) -> Void)? = nil) {
    DispatchQueue.global().async {
        let (out, code) = runCduoSync(args)
        DispatchQueue.main.async { completion?(out, code) }
    }
}

func runCduoSync(_ args: [String]) -> (String, Int32) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    p.arguments = [cduoBin] + args
    var e = ProcessInfo.processInfo.environment
    e["NO_COLOR"] = "1"
    p.environment = e
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    do { try p.run() } catch { return ("", -1) }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (String(data: data, encoding: .utf8) ?? "", p.terminationStatus)
}

/// 在「终端」App 里跑 cduo 子命令。用完整路径，不依赖 PATH 里有没有 ~/.local/bin。
func openInTerminal(_ sub: String) {
    let path = cduoDir + "/run.command"
    let q = { (s: String) in "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    let script = "#!/bin/zsh -l\nclear\n/usr/bin/python3 \(q(cduoBin)) \(sub)\necho\nread -k1 \"?完成。按任意键关闭此窗口…\"\n"
    try? script.write(toFile: path, atomically: true, encoding: .utf8)
    chmod(path, 0o755)
    NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
                            configuration: NSWorkspace.OpenConfiguration())
}

func requestAccessibility() {
    let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
    if !AXIsProcessTrustedWithOptions(opts) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}

func postKey(_ code: CGKeyCode, command: Bool = false) {
    let src = CGEventSource(stateID: .hidSystemState)
    let down = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true)
    let up = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false)
    if command { down?.flags = .maskCommand; up?.flags = .maskCommand }
    down?.post(tap: .cghidEventTap)
    up?.post(tap: .cghidEventTap)
}

/// 距离你上一次碰键盘/鼠标过去了几秒
func userIdleSeconds() -> Double {
    CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: UInt32.max)!)
}

let claudeBundleID = "com.anthropic.claudefordesktop"

/// Claude 当前窗口的标题（要有辅助功能权限；拿不到就是 nil）
func claudeWindowTitle() -> String? {
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: claudeBundleID).first else { return nil }
    let ax = AXUIElementCreateApplication(app.processIdentifier)
    var win: CFTypeRef?
    guard AXUIElementCopyAttributeValue(ax, kAXFocusedWindowAttribute as CFString, &win) == .success,
          let w = win, CFGetTypeID(w) == AXUIElementGetTypeID() else { return nil }
    var title: CFTypeRef?
    guard AXUIElementCopyAttributeValue(w as! AXUIElement, kAXTitleAttribute as CFString, &title) == .success else { return nil }
    return title as? String
}

/// 粘贴前的核对：窗口标题如果带着会话信息（不是空的，也不只是 "Claude"），就必须对得上要续上的会话。
/// 标题里没有会话信息时没法核对，返回 true，交给发送后的核对（cduo resume check）。
func windowMatchesSession(_ windowTitle: String?, sessionTitle: String) -> Bool {
    let generic: Set<String> = ["", "claude", "claude code", "claude desktop"]
    var core = (windowTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    for suffix in [" - Claude", " – Claude", " — Claude", " | Claude"] where core.hasSuffix(suffix) {
        core = String(core.dropLast(suffix.count))
    }
    core = core.trimmingCharacters(in: CharacterSet(charactersIn: " …."))
    let st = sessionTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    if generic.contains(core.lowercased()) || st.isEmpty { return true }
    return st.contains(core) || core.contains(st)
}

/// 把剪贴板里的全部内容（文字、图片、文件……每种格式）存下来，用完原样放回去
func savePasteboard(_ pb: NSPasteboard) -> [NSPasteboardItem] {
    (pb.pasteboardItems ?? []).map { item in
        let copy = NSPasteboardItem()
        for t in item.types {
            if let d = item.data(forType: t) { copy.setData(d, forType: t) }
        }
        return copy
    }
}

func restorePasteboard(_ pb: NSPasteboard, _ items: [NSPasteboardItem]) {
    pb.clearContents()
    if !items.isEmpty { pb.writeObjects(items) }
}

// MARK: - 数据模型

struct Acct: Identifiable, Equatable {
    var id: String { name }
    var name = "", label = "", email = ""
    var util: Double? = nil, running = false, resetsAt: Double? = nil
    var error: String? = nil, hasProfile = false, current = false
    var errorKind: String? = nil          // login / network / denied / ratelimit / server / other
    var staleUtil: Double? = nil, okAt: Double? = nil   // 读不到时：上次读到的数、什么时候读到的
    var weekly: Double? = nil, eta: Double? = nil       // 本周已用、按现在的速度几点用完
    var prewarm = true
    var pingFailKind: String? = nil, pingRetryAt: Double? = nil
    var display: String { label.isEmpty ? name : label }
}

/// 「12 分钟」「2 小时」：过去了多久
func ago(_ ts: Double?) -> String {
    guard let ts = ts else { return "" }
    let mins = max(Int((Date().timeIntervalSince1970 - ts) / 60), 1)
    return mins < 60 ? "\(mins) 分钟" : "\(mins / 60) 小时"
}

/// 出错类型给人看的说法
func errorText(_ kind: String?) -> String {
    switch kind {
    case "login": return "登录失效，需要重新登录"
    case "network": return "网络/代理连不上"
    case "denied": return "请求被拒（多半是代理）"
    case "ratelimit": return "接口限流，稍后自动再查"
    case "server": return "Anthropic 服务端出错"
    default: return "额度读取失败"
    }
}

struct Event: Identifiable {
    let id = UUID()
    let time: Double
    let icon: String
    let text: String
}

final class Model: ObservableObject {
    @Published var accts: [Acct] = []
    @Published var configured = true
    @Published var loaded = false
    @Published var recAction = ""
    @Published var recTarget: String? = nil
    @Published var recReason = ""
    @Published var nextWhy = ""
    @Published var nextAt: Double? = nil
    @Published var nextName: String? = nil
    @Published var switchingTo: String? = nil
    @Published var switchPhase = ""
    @Published var mode = "notify"
    @Published var threshold = 95.0
    @Published var prewarm = true
    @Published var confirm = true
    @Published var loginItem = true
    @Published var pinOrg = true
    @Published var pinReady = true
    @Published var orgName = "主组织"
    @Published var workStart = "10:00"
    @Published var workEnd = "01:00"
    @Published var version = ""
    @Published var refreshing = false
    @Published var showSettings = false
    @Published var confirmFor: String? = nil
    @Published var autoResume = true
    @Published var axTrusted = AXIsProcessTrusted()
    @Published var interrupted: [String] = []
    @Published var waitUntil: Double? = nil
    @Published var waitCount = 0
    @Published var resuming: String? = nil
    @Published var recUrgent = false
    @Published var recKind = ""
    @Published var netDownSince: Double? = nil
    @Published var notifyExpiring = false
    var onSwitchError: ((String) -> Void)?

    /// 当前号按现在的速度 1 小时内会用完（而且在刷新之前）：返回预计时间
    var etaSoon: Double? {
        guard let e = current?.eta, e - Date().timeIntervalSince1970 <= 3600 else { return nil }
        return e
    }

    /// 需要你动手的时候，菜单栏图标后面才亮橙点：快用完、被打断、要登录、预计很快用完。
    /// 「另一个号快到期，可以先用它」不算，只在面板里显示
    var actionable: Bool {
        (recAction == "switch" && recUrgent) || recAction == "need_login" || !interrupted.isEmpty || etaSoon != nil
    }

    /// 当前号快用完、正在等刷新、有被打断的任务、或预计很快用完：查得勤一点
    var hot: Bool { (current?.util ?? 0) >= 85 || waitUntil != nil || !interrupted.isEmpty || etaSoon != nil }

    func display(_ n: String?) -> String {
        guard let n = n else { return "?" }
        return accts.first(where: { $0.name == n })?.display ?? n
    }

    var current: Acct? { accts.first(where: { $0.current }) }

    /// 说"全部账号"时用：两个号就说"两个号"，更多就说"3 个号"
    var allText: String { accts.count == 2 || accts.isEmpty ? "两个号" : "\(accts.count) 个号" }

    /// 5 小时按号数均分：2 个号错开 2.5 小时，3 个号错开 1 小时 40 分……
    var gapText: String {
        let mins = 300 / max(accts.count, 2)
        let h = mins / 60, mm = mins % 60
        if mm == 30 { return "\(h).5 小时" }
        if mm == 0 { return "\(h) 小时" }
        return h == 0 ? "\(mm) 分钟" : "\(h) 小时 \(mm) 分"
    }

    var events: [Event] {
        var ev: [Event] = []
        for a in accts where a.running {
            if let r = a.resetsAt { ev.append(Event(time: r, icon: "arrow.clockwise", text: "\(a.display) 额度刷新")) }
        }
        if prewarm, netDownSince == nil, let at = nextAt, let n = nextName {   // 断网时预热暂停，不列出来
            ev.append(Event(time: at, icon: "play.fill", text: "\(display(n)) 开始计时"))
        }
        return ev.sorted { $0.time < $1.time }.prefix(3).map { $0 }
    }

    func refresh(network: Bool) {
        refreshing = network
        runCduo(network ? ["status", "--json"] : ["status", "--json", "--cached"]) { [weak self] out, _ in
            self?.apply(out); self?.refreshing = false
        }
    }

    func refreshSync() { apply(runCduoSync(["status", "--json", "--cached"]).0) }

    func apply(_ out: String) {
        guard let line = out.split(separator: "\n").last(where: { $0.hasPrefix("{") }),
              let data = line.data(using: .utf8),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        loaded = true
        accts = (j["accounts"] as? [[String: Any]] ?? []).map {
            let pf = $0["ping_fail"] as? [String: Any]
            return Acct(name: $0["name"] as? String ?? "?", label: $0["label"] as? String ?? "",
                        email: $0["email"] as? String ?? "",
                        util: $0["util"] as? Double, running: $0["running"] as? Bool ?? false,
                        resetsAt: $0["resets_at"] as? Double, error: $0["error"] as? String,
                        hasProfile: $0["has_profile"] as? Bool ?? false, current: $0["desktop_current"] as? Bool ?? false,
                        errorKind: $0["error_kind"] as? String, staleUtil: $0["stale_util"] as? Double,
                        okAt: $0["ok_at"] as? Double, weekly: $0["weekly_util"] as? Double, eta: $0["eta"] as? Double,
                        prewarm: $0["prewarm"] as? Bool ?? true,
                        pingFailKind: pf?["kind"] as? String, pingRetryAt: pf?["retry_at"] as? Double)
        }
        netDownSince = j["net_down_since"] as? Double
        configured = !accts.isEmpty
        version = j["version"] as? String ?? ""
        let rec = j["recommend"] as? [String: Any] ?? [:]
        recAction = rec["action"] as? String ?? ""
        recTarget = rec["target"] as? String
        recReason = rec["reason"] as? String ?? ""
        recUrgent = rec["urgent"] as? Bool ?? false
        recKind = rec["kind"] as? String ?? ""
        let np = j["next_ping"] as? [String: Any] ?? [:]
        nextWhy = np["why"] as? String ?? ""
        nextAt = np["at"] as? Double
        nextName = np["name"] as? String
        let sw = j["switching"] as? [String: Any]
        switchingTo = sw?["to"] as? String
        switchPhase = sw?["phase"] as? String ?? ""
        interrupted = (j["interrupted"] as? [[String: Any]] ?? []).map { $0["title"] as? String ?? "" }
        let rw = j["resume_wait"] as? [String: Any]
        waitUntil = rw == nil ? nil : (rw?["until"] as? Double ?? 0)
        waitCount = rw?["count"] as? Int ?? 0
        resuming = (j["resume_active"] as? [[String: Any]])?.first.map { $0["title"] as? String ?? "" }
        axTrusted = AXIsProcessTrusted()
        if let s = j["settings"] as? [String: Any] {
            mode = s["auto_switch"] as? String ?? "notify"
            threshold = s["switch_threshold"] as? Double ?? 95
            prewarm = s["prewarm_enabled"] as? Bool ?? true
            confirm = s["confirm_switch"] as? Bool ?? true
            loginItem = s["login_item"] as? Bool ?? true
            pinOrg = s["pin_org"] as? Bool ?? true
            autoResume = s["auto_resume"] as? Bool ?? true
            notifyExpiring = s["notify_expiring"] as? Bool ?? false
            pinReady = s["pin_org_ready"] as? Bool ?? true
            if let o = (s["org_names"] as? [String])?.first { orgName = o.components(separatedBy: " - ").first ?? o }
            if let w = s["work_hours"] as? [String: Any] {
                workStart = w["start"] as? String ?? workStart
                workEnd = w["end"] as? String ?? workEnd
            } else if let a = s["active_hours"] as? [String: Any], let st = a["start"] as? String {
                let h = (Int(st.prefix(2)) ?? 6) + 4
                workStart = String(format: "%02d:%@", h % 24, String(st.suffix(2)))
                workEnd = a["end"] as? String ?? workEnd
            }
        }
    }

    func set(_ key: String, _ value: String) {
        runCduo(["config", key, value]) { [weak self] _, _ in self?.refresh(network: false) }
    }

    func requestSwitch(_ name: String) {
        if confirm && confirmFor != name { confirmFor = name; return }
        confirmFor = nil
        startSwitch(name)
    }

    func startSwitch(_ name: String) {
        switchingTo = name; switchPhase = "waiting"
        runCduo(["switch", name, "--after-turn"]) { [weak self] out, code in
            if code != 0 { self?.onSwitchError?(out.split(separator: "\n").last.map(String.init) ?? "切换没有完成") }
            self?.refresh(network: true)
        }
    }
}

// MARK: - 视觉组件

func levelColors(_ u: Double?) -> [Color] {
    guard let u = u else { return [Color.gray.opacity(0.5), Color.gray.opacity(0.5)] }
    if u < 70 { return [Color(red: 0.20, green: 0.78, blue: 0.55), Color(red: 0.16, green: 0.62, blue: 0.86)] }
    if u < 90 { return [Color(red: 1.0, green: 0.72, blue: 0.20), Color(red: 0.98, green: 0.50, blue: 0.20)] }
    return [Color(red: 1.0, green: 0.42, blue: 0.35), Color(red: 0.90, green: 0.20, blue: 0.35)]
}

struct Ring: View {
    let util: Double?
    let size: CGFloat
    var body: some View {
        let frac = CGFloat(min(max((util ?? 0) / 100, 0), 1))
        let cols = levelColors(util)
        ZStack {
            Circle().stroke(Color.primary.opacity(0.08), lineWidth: 8)
            Circle()
                .trim(from: 0, to: max(frac, util == nil ? 0 : 0.012))
                .stroke(AngularGradient(gradient: Gradient(colors: cols + [cols[0]]), center: .center),
                        style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                if let u = util {
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        Text(String(format: "%.0f", u)).font(.system(size: 22, weight: .semibold, design: .rounded))
                        Text("%").font(.system(size: 12, weight: .semibold, design: .rounded))
                    }
                    Text("已用").font(.system(size: 10)).foregroundColor(.secondary)
                } else {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 18)).foregroundColor(.orange)
                }
            }
        }
        .frame(width: size, height: size)
    }
}

struct Pill: View {
    let text: String
    var color: Color = .accentColor
    var body: some View {
        Text(text).font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 7).padding(.vertical, 2.5)
            .background(Capsule().fill(color.opacity(0.16)))
            .foregroundColor(color)
    }
}

struct AccountCard: View {
    @ObservedObject var m: Model
    let a: Acct
    var recommended: Bool { (m.recAction == "switch" || m.recAction == "need_login") && m.recTarget == a.name }
    /// 需要你动手的推荐（快用完、要登录）用橙色强调；「快到期，可以先用」只轻轻提示一下
    var urgent: Bool { recommended && (m.recUrgent || m.recAction == "need_login") }

    var subtitle: String {
        if a.util == nil { return errorText(a.errorKind) }
        if !a.hasProfile && !a.current { return "还没在桌面版登录" }
        return a.running ? "\(hhmm(a.resetsAt)) 刷新" : "满额 · 未开始计时"
    }

    /// 第二行小字：按重要程度只显示一条
    var detail: (String, Color)? {
        if let e = a.eta { return ("按现在的速度约 \(hhmm(e)) 用完", .orange) }
        if let k = a.pingFailKind, a.util != nil {
            let why = ["network": "网络", "denied": "请求被拒", "ratelimit": "限流", "login": "要登录"][k] ?? "出错"
            return ("预热失败（\(why)），" + (a.pingRetryAt.map { "\(hhmm($0)) 再试" } ?? "稍后再试"), .orange)
        }
        if a.util == nil, a.staleUtil != nil, let t = a.okAt { return ("显示的是 \(ago(t))前的数据", .secondary) }
        return nil
    }

    /// 第三行小字：周额度、是否参与预热
    var extra: String? {
        var parts: [String] = []
        if let w = a.weekly, w >= 1 { parts.append("本周已用 \(Int(w.rounded()))%") }
        if !a.prewarm { parts.append("不参与预热") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text(a.display).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 4)
                if a.current { Pill(text: "使用中") }
                else if urgent { Pill(text: "推荐", color: .orange) }
                else if recommended { Pill(text: "可先用", color: .gray) }
            }
            Ring(util: a.util ?? a.staleUtil, size: 78)
                .opacity(a.util == nil && a.staleUtil != nil ? 0.4 : 1)   // 读不到时显示上次的数，变淡
            VStack(spacing: 3) {
                Text(subtitle).font(.system(size: 11))
                    .foregroundColor(a.util == nil || (!a.hasProfile && !a.current) ? .orange : .secondary)
                if let d = detail {
                    Text(d.0).font(.system(size: 10)).foregroundColor(d.1).lineLimit(1).minimumScaleFactor(0.8)
                }
                if let x = extra { Text(x).font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1) }
            }
            action
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(a.current ? 0.07 : 0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(a.current ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.06), lineWidth: a.current ? 1.5 : 1)
        )
    }

    @ViewBuilder var action: some View {
        if a.util == nil {
            if a.errorKind == "login" {          // 只有登录真失效了才让你去重新登录
                Button("重新登录") { openInTerminal("login \(a.name)") }
                    .buttonStyle(.bordered).controlSize(.small)
            } else {                             // 网络、代理、限流：重新登录解决不了，重试就好
                Button { m.refresh(network: true) } label: { Label("重试", systemImage: "arrow.clockwise") }
                    .buttonStyle(.bordered).controlSize(.small).disabled(m.refreshing)
            }
        } else if a.current {
            Text(m.mode == "idle" ? "用完自动换走" : "正在使用")
                .font(.system(size: 11)).foregroundColor(.secondary).frame(height: 22)
        } else if m.switchingTo != nil {
            ProgressView().controlSize(.small).frame(height: 22)
        } else if m.confirmFor == a.name {
            HStack(spacing: 6) {
                Button("取消") { m.confirmFor = nil }.buttonStyle(.bordered).controlSize(.small)
                Button("确认切换") { m.requestSwitch(a.name) }.buttonStyle(.borderedProminent).controlSize(.small)
            }
        } else if !a.hasProfile {
            if urgent {
                Button { openInTerminal("login-desktop \(a.name)") } label: { Label("登录桌面版", systemImage: "person.crop.circle.badge.plus").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).controlSize(.small).tint(.orange)
                    .help("在 Claude 桌面版里登录这个号一次，之后就能一键切换")
            } else {
                Button { openInTerminal("login-desktop \(a.name)") } label: { Label("登录桌面版", systemImage: "person.crop.circle.badge.plus").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered).controlSize(.small)
                    .help("在 Claude 桌面版里登录这个号一次，之后就能一键切换")
            }
        } else if a.hasProfile {
            if urgent {
                Button { m.requestSwitch(a.name) } label: { Label("切换", systemImage: "arrow.left.arrow.right").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).controlSize(.small).tint(.orange)
            } else {
                Button { m.requestSwitch(a.name) } label: { Label("切换", systemImage: "arrow.left.arrow.right").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered).controlSize(.small)
            }
        }
    }
}

struct Banner: View {
    let icon: String, text: String, color: Color
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundColor(color).font(.system(size: 13, weight: .semibold))
            Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let t = actionTitle, let act = action {
                Button(t, action: act).buttonStyle(.bordered).controlSize(.small)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(color.opacity(0.12)))
    }
}

/// Cduo 标志：和 App 图标一致（橙色圆角方块 + 两个交错圆环）
struct Logo: View {
    let size: CGFloat
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.85, green: 0.47, blue: 0.34), Color(red: 0.62, green: 0.30, blue: 0.22)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            Circle().stroke(Color.white.opacity(0.95), lineWidth: size * 0.075)
                .frame(width: size * 0.38, height: size * 0.38).offset(x: -size * 0.11)
            Circle().stroke(Color.white.opacity(0.6), lineWidth: size * 0.075)
                .frame(width: size * 0.38, height: size * 0.38).offset(x: size * 0.11)
        }
        .frame(width: size, height: size)
    }
}

struct SectionTitle: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct IconButton: View {
    let icon: String, help: String, action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 13, weight: .medium)).frame(width: 26, height: 26)
                .background(Circle().fill(Color.primary.opacity(0.06)))
        }
        .buttonStyle(.plain).help(help)
    }
}

// MARK: - 主面板

struct MainView: View {
    @ObservedObject var m: Model
    var modeName: String { ["off": "只显示", "notify": "快用完提醒", "idle": "自动换号"][m.mode] ?? "快用完提醒" }

    var body: some View {
        VStack(spacing: 14) {
            header
            if !m.configured && m.loaded { welcome }
            else {
                cards
                status
                if !m.events.isEmpty { upcoming }
            }
        }
        .padding(16)
        .frame(width: panelWidth)
    }

    /// 每行两张卡片；超过 4 个号（两行）就放进可以滚动的区域，免得面板比屏幕还高，
    /// 这时正在用的号排在最前面，不会被藏在下面（4 个号以内保持原来的顺序，换号时卡片不跳动）
    @ViewBuilder var cards: some View {
        let list = m.accts.count > 4 ? m.accts.filter { $0.current } + m.accts.filter { !$0.current } : m.accts
        let grid = LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            ForEach(list) { a in AccountCard(m: m, a: a) }
        }
        if m.accts.count > 4 {
            ScrollView(.vertical, showsIndicators: true) { grid }.frame(height: cardsScrollHeight)
        } else {
            grid
        }
    }

    var header: some View {
        HStack(spacing: 10) {
            Logo(size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text("Cduo").font(.system(size: 14, weight: .bold))
                Text(m.configured ? "\(modeName) · \(m.allText)错峰使用" : "多个 Claude 号，额度不浪费")
                    .font(.system(size: 11)).foregroundColor(.secondary)
            }
            Spacer()
            IconButton(icon: "arrow.clockwise", help: "刷新额度") { m.refresh(network: true) }
                .rotationEffect(.degrees(m.refreshing ? 180 : 0))
                .animation(.easeInOut(duration: 0.5), value: m.refreshing)
            IconButton(icon: "gearshape", help: "设置") { withAnimation(.easeInOut(duration: 0.18)) { m.showSettings = true } }
        }
    }

    @ViewBuilder var status: some View {
        if let to = m.switchingTo {
            Banner(icon: "arrow.triangle.2.circlepath",
                   text: m.switchPhase == "waiting" ? "等 Claude 这一轮回复结束，就切到 \(m.display(to))" : "正在重启 Claude，切到 \(m.display(to))…",
                   color: .accentColor)
        } else if let t = m.resuming {
            Banner(icon: "play.circle.fill", text: "正在续上被额度打断的任务「\(t.isEmpty ? "会话" : t)」…", color: .accentColor)
        } else if let since = m.netDownSince {
            Banner(icon: "wifi.exclamationmark",
                   text: "代理/网络连不上（\(hhmm(since)) 起），额度是之前读到的。自动计时先暂停，恢复后自动继续。",
                   color: .orange, actionTitle: "重试", action: { m.refresh(network: true) })
        } else if let w = m.waitUntil {
            Banner(icon: "hourglass",
                   text: "\(m.allText)都用完了。" + (w > 0 ? "\(hhmm(w)) 有号刷新后自动换过去" : "等额度刷新后自动换过去")
                       + (m.waitCount > 0 && m.autoResume ? "，并续上 \(m.waitCount) 个被打断的任务" : ""),
                   color: .red)
        } else if !m.interrupted.isEmpty && m.mode != "idle" && m.recAction == "switch" {
            Banner(icon: "exclamationmark.circle.fill",
                   text: "任务「\(m.interrupted[0])」被额度打断了。切到 \(m.display(m.recTarget)) 后" + (m.autoResume ? "会自动续上" : "发一句「继续」即可"),
                   color: .orange)
        } else if m.recAction == "need_login" {
            Banner(icon: "person.crop.circle.badge.exclamationmark", text: m.recReason, color: .orange)
        } else if m.recAction == "switch" && m.recUrgent {
            Banner(icon: "lightbulb.fill", text: "建议切到 \(m.display(m.recTarget))：\(m.recReason)", color: .orange)
        } else if let e = m.etaSoon {
            Banner(icon: "speedometer",
                   text: "按现在的速度，\(m.current?.display ?? "当前号")约 \(hhmm(e)) 用完（\(hhmm(m.current?.resetsAt)) 才刷新）。"
                       + "到时可以换个号，或者先 /compact 一下长对话。", color: .orange)
        } else if m.recAction == "wait" {
            Banner(icon: "hourglass", text: m.recReason, color: .red)
        } else if m.autoResume && !m.axTrusted {
            Banner(icon: "hand.raised.fill",
                   text: "「自动续上」需要「辅助功能」授权（升级后系统会作废旧授权）。没有授权时，被额度打断的任务只能手动续上。",
                   color: .gray, actionTitle: "去授权",
                   action: { requestAccessibility(); DispatchQueue.main.asyncAfter(deadline: .now() + 2) { m.axTrusted = AXIsProcessTrusted() } })
        } else if m.recAction == "switch" {
            // 「另一个号快到期，可以先用它」：只是提示，不抢眼
            Banner(icon: "lightbulb", text: "可以先用 \(m.display(m.recTarget))：\(m.recReason)", color: .gray)
        } else if !m.prewarm {
            Banner(icon: "pause.circle", text: "自动提前计时已关闭，\(m.allText)的刷新时间不会自动错开", color: .gray)
        }
    }

    var upcoming: some View {
        VStack(spacing: 8) {
            SectionTitle(text: "接下来")
            VStack(spacing: 0) {
                ForEach(Array(m.events.enumerated()), id: \.element.id) { i, e in
                    HStack(spacing: 10) {
                        Text(e.time <= Date().timeIntervalSince1970 + 60 ? "现在" : hhmm(e.time))
                            .font(.system(size: 12, weight: .medium, design: .rounded)).monospacedDigit()
                            .frame(width: 64, alignment: .leading)
                        Image(systemName: e.icon).font(.system(size: 9, weight: .bold))
                            .foregroundColor(.white).frame(width: 18, height: 18)
                            .background(Circle().fill(e.icon == "play.fill" ? Color.accentColor : Color.green))
                        Text(e.text).font(.system(size: 12))
                        Spacer()
                    }
                    .padding(.vertical, 7).padding(.horizontal, 10)
                    if i < m.events.count - 1 { Divider().padding(.leading, 10) }
                }
            }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.035)))
        }
    }

    var welcome: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.2.circle").font(.system(size: 40)).foregroundColor(.accentColor)
            Text("还没有添加账号").font(.system(size: 14, weight: .semibold))
            Text("设置向导会带你登录你的号（两个或更多），每个号大约两三分钟。过程中 Claude 会重启几次。")
                .font(.system(size: 12)).foregroundColor(.secondary).multilineTextAlignment(.center)
            Button { openInTerminal("setup") } label: { Text("开始设置").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent).controlSize(.large)
        }
        .padding(.vertical, 10)
    }
}

// MARK: - 设置面板

struct SettingsView: View {
    @ObservedObject var m: Model
    @State private var names: [String: String] = [:]
    @State private var removing: String? = nil     // 正在确认要移除的号
    @State private var purge = false               // 移除时是否同时清除本机的登录和备份

    /// removing / purge 只给自检截图用（直接画出「移除确认」打开的样子）
    init(m: Model, removing: String? = nil, purge: Bool = false) {
        self.m = m
        _removing = State(initialValue: removing)
        _purge = State(initialValue: purge)
    }

    func binding<T>(_ get: @escaping () -> T, _ set: @escaping (T) -> Void) -> Binding<T> { Binding(get: get, set: set) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { withAnimation(.easeInOut(duration: 0.18)) { m.showSettings = false } } label: {
                    Label("返回", systemImage: "chevron.left").font(.system(size: 12, weight: .medium))
                }.buttonStyle(.plain).foregroundColor(.accentColor)
                Spacer()
                Text("设置").font(.system(size: 14, weight: .bold))
                Spacer()
                Text("返回").font(.system(size: 12)).hidden()
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)
            Divider()
            ScrollView {
                VStack(spacing: 16) {
                    group("切换") {
                        Picker("", selection: binding({ m.mode }, { m.mode = $0; m.set("auto_switch", $0) })) {
                            // 分段控件每段一样宽（按最长那段算），名字太长会把整页撑出面板，所以要短
                            Text("只显示").tag("off"); Text("快用完提醒").tag("notify"); Text("自动换号").tag("idle")
                        }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: .infinity)
                        Text(["off": "只显示额度，不发任何通知。",
                              "notify": "快用完、或按现在的速度会在刷新前用完时提醒你，通知上直接点「切换」。其他时候不打扰。",
                              "idle": "用完才换号，一点不浪费。\(m.allText)都用完时，等先刷新的那个。"][m.mode] ?? "")
                            .font(.system(size: 11)).foregroundColor(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                        if m.mode == "notify" {
                            row("提醒我先用快到期的额度", note: "另一个号快刷新、额度还剩很多时，发一条不响铃的提醒。默认只在面板里显示") {
                                toggle({ m.notifyExpiring }, { m.notifyExpiring = $0; m.set("notify_expiring", $0 ? "on" : "off") })
                            }
                        }
                        if m.mode != "idle" {
                            row("用到多少算「快用完」") {
                                Picker("", selection: binding({ Int(m.threshold) }, { m.threshold = Double($0); m.set("switch_threshold", "\($0)") })) {
                                    Text("80%").tag(80); Text("90%").tag(90); Text("95%").tag(95)
                                }.pickerStyle(.segmented).labelsHidden().frame(width: 150)
                            }
                        }
                        row("自动续上被打断的任务", note: "只在额度用完、任务被迫中断时，换号后替你发一句「继续」") {
                            toggle({ m.autoResume }, { m.autoResume = $0; m.set("auto_resume", $0 ? "on" : "off") })
                        }
                        if m.autoResume && !m.axTrusted {
                            HStack(spacing: 8) {
                                Image(systemName: "hand.raised.fill").foregroundColor(.orange).font(.system(size: 12))
                                Text("需要「辅助功能」权限才能替你按发送").font(.system(size: 11)).foregroundColor(.secondary)
                                Spacer(minLength: 4)
                                Button("去授权") { requestAccessibility(); DispatchQueue.main.asyncAfter(deadline: .now() + 2) { m.axTrusted = AXIsProcessTrusted() } }
                                    .buttonStyle(.bordered).controlSize(.small)
                            }
                        }
                        row("切换前先确认") { toggle({ m.confirm }, { m.confirm = $0; m.set("confirm_switch", $0 ? "on" : "off") }) }
                    }
                    group("自动提前计时") {
                        row("开启", note: "\(m.allText)依次错开 \(m.gapText) 刷新额度") {
                            toggle({ m.prewarm }, { m.prewarm = $0; m.set("prewarm_enabled", $0 ? "on" : "off") })
                        }
                        if m.prewarm {
                            row("一般几点开始用") { timePicker(m.workStart, Array(5...13)) { v in m.workStart = v; m.set("work_hours", "\(v)-\(m.workEnd)") } }
                            row("一般几点收工") { timePicker(m.workEnd, [21, 22, 23, 0, 1, 2, 3, 4]) { v in m.workEnd = v; m.set("work_hours", "\(m.workStart)-\(v)") } }
                            Text("开始用之前约 4 小时，第一个号就开始计时；开工 1 小时后就会刷新一次额度。")
                                .font(.system(size: 11)).foregroundColor(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    group("组织") {
                        row("始终使用 \(m.orgName)", note: m.pinOrg && !m.pinReady ? "下次在该组织里用 Claude 时生效" : "换号后自动进入这个组织") {
                            toggle({ m.pinOrg }, { m.pinOrg = $0; m.set("pin_org", $0 ? "on" : "off") })
                        }
                    }
                    group("账号") {
                        ForEach(m.accts) { a in
                            HStack(spacing: 8) {
                                TextField(a.name, text: binding({ names[a.name] ?? a.display }, { names[a.name] = $0 }))
                                    .textFieldStyle(.roundedBorder).frame(width: 110)
                                    .onSubmit { if let n = names[a.name], !n.isEmpty { runCduo(["rename", a.name, n]) { _, _ in m.refresh(network: false) } } }
                                Text(a.email).font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 4)
                                Button { runCduo(["ping", a.name]) { _, _ in m.refresh(network: false) } } label: { Image(systemName: "play.circle") }
                                    .buttonStyle(.borderless).help("让这个号立刻开始计时")
                                Menu {
                                    Toggle("参与自动预热", isOn: binding({ a.prewarm }, { v in
                                        runCduo(["prewarm", a.name, v ? "on" : "off"]) { _, _ in m.refresh(network: false) }
                                    }))
                                    Button("重新登录…") { openInTerminal("login \(a.name)") }
                                    Divider()
                                    Button(a.current ? "移除…（先切到别的号）" : "移除…") { purge = false; removing = a.name }
                                        .disabled(a.current)
                                } label: { Image(systemName: "ellipsis.circle") }
                                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                                    .help("预热、重新登录、移除")
                            }
                            if removing == a.name {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("移除「\(a.display)」？").font(.system(size: 12, weight: .semibold))
                                    Toggle(isOn: $purge) {      // 标题用可换行的 Text：AppKit 勾选框的文字默认不换行，会把整页撑宽
                                        Text("同时清除它在本机的登录和备份（借来的号用完建议勾上）")
                                            .font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                                    }
                                    .toggleStyle(.checkbox)
                                    Text(purge ? "会删除它的命令行登录（含钥匙串）、桌面版登录快照和含它登录的旧备份。"
                                               : "保留它的登录，以后加回来不用重新授权。")
                                        .font(.system(size: 11)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                                    HStack {
                                        Spacer()
                                        Button("取消") { removing = nil }.buttonStyle(.bordered).controlSize(.small)
                                        Button("移除") {
                                            runCduo(["remove", a.name] + (purge ? ["--purge"] : [])) { _, _ in
                                                removing = nil; m.refresh(network: false)
                                            }
                                        }.buttonStyle(.borderedProminent).controlSize(.small).tint(.red)
                                    }
                                }
                                .padding(10)
                                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.red.opacity(0.08)))
                            }
                        }
                        Button { openInTerminal("setup --add") } label: { Label("添加账号", systemImage: "plus.circle") }
                            .buttonStyle(.borderless).frame(maxWidth: .infinity, alignment: .leading)
                            .help("在「终端」里登录一个新号，加进来一起错峰")
                        Text("改完名字按回车保存；▶︎ 让这个号立刻开始计时；⋯ 里可以暂停预热、重新登录、移除。")
                            .font(.system(size: 11)).foregroundColor(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    group("通用") {
                        row("开机自动启动") {
                            toggle({ m.loginItem }, { v in m.loginItem = v; runCduo(["agents", v ? "login-on" : "login-off"]) { _, _ in m.refresh(network: false) } })
                        }
                        HStack(spacing: 8) {
                            tool("同步会话", "arrow.triangle.2.circlepath") { runCduo(["sync"]) }
                            tool("自检", "stethoscope") { openInTerminal("doctor") }
                            tool("设置向导", "wand.and.stars") { openInTerminal("setup") }
                            tool("日志", "doc.text") { NSWorkspace.shared.open(URL(fileURLWithPath: cduoDir + "/logs/cduo.log")) }
                        }
                    }
                    HStack {
                        Text("Cduo \(m.version)").font(.system(size: 11)).foregroundColor(.secondary)
                        Spacer()
                        Button("退出 Cduo") { try? FileManager.default.removeItem(atPath: cduoDir + "/.menubar_alive"); exit(0) }
                            .buttonStyle(.bordered).controlSize(.small)
                    }
                }
                .padding(16)
            }
            .frame(maxHeight: dumpMode ? .infinity : 520)
        }
        .frame(width: panelWidth)
    }

    func group<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(spacing: 8) {
            SectionTitle(text: title)
            VStack(spacing: 10) { content() }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.04)))
        }
    }

    func row<C: View>(_ title: String, note: String? = nil, @ViewBuilder _ control: () -> C) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12))
                if let n = note { Text(n).font(.system(size: 10)).foregroundColor(.secondary) }
            }
            Spacer(minLength: 4)
            control()
        }
    }

    func toggle(_ get: @escaping () -> Bool, _ set: @escaping (Bool) -> Void) -> some View {
        Toggle("", isOn: binding(get, set)).toggleStyle(.switch).labelsHidden().controlSize(.small)
    }

    func timePicker(_ value: String, _ hours: [Int], _ set: @escaping (String) -> Void) -> some View {
        Picker("", selection: binding({ value }, set)) {
            ForEach(hours, id: \.self) { h in Text(String(format: "%02d:00", h)).tag(String(format: "%02d:00", h)) }
        }.labelsHidden().frame(width: 86)
    }

    func tool(_ title: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 14))
                Text(title).font(.system(size: 10))
            }
            .frame(maxWidth: .infinity).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.05)))
        }.buttonStyle(.plain)
    }
}

struct RootView: View {
    @ObservedObject var m: Model
    var body: some View {
        Group {
            if m.showSettings { SettingsView(m: m).transition(.move(edge: .trailing).combined(with: .opacity)) }
            else { MainView(m: m).transition(.move(edge: .leading).combined(with: .opacity)) }
        }
    }
}

// MARK: - 菜单栏图标：每个号一个圆环（最多 5 个），弧长=已用额度，正在用的号中间有实心点

/// 号太多时菜单栏放不下：最多画 5 个圆环，正在用的号一定在里面
func iconAccounts(_ accts: [Acct], max n: Int = 5) -> [Acct] {
    if accts.isEmpty { return [Acct(), Acct()] }
    guard accts.count > n else { return accts }
    var list = Array(accts.prefix(n))
    if let cur = accts.first(where: { $0.current }), !list.contains(where: { $0.current }) { list[n - 1] = cur }
    return list
}

/// 自检用：把菜单栏图标放大画到白底上存成 PNG
func dumpStatusIcon(_ accts: [Acct], _ path: String) {
    let icon = statusIcon(accts)
    let k: CGFloat = 4
    let img = NSImage(size: NSSize(width: icon.size.width * k + 16, height: icon.size.height * k + 16), flipped: false) { r in
        NSColor.white.setFill(); r.fill()
        icon.draw(in: NSRect(x: 8, y: 8, width: icon.size.width * k, height: icon.size.height * k))
        return true
    }
    guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { return }
    try? png.write(to: URL(fileURLWithPath: path))
}

func statusIcon(_ accts: [Acct]) -> NSImage {
    let list = iconAccounts(accts)
    let w: CGFloat = 17 + CGFloat(max(list.count - 1, 0)) * 14
    let img = NSImage(size: NSSize(width: w, height: 18), flipped: false) { _ in
        for (i, a) in list.enumerated() {
            let c = NSPoint(x: 8.5 + CGFloat(i) * 14, y: 9)
            let r: CGFloat = 6.2
            let track = NSBezierPath()
            track.appendArc(withCenter: c, radius: r, startAngle: 0, endAngle: 360)
            track.lineWidth = 1.6
            NSColor.black.withAlphaComponent(0.32).setStroke(); track.stroke()
            let frac = CGFloat(min(max((a.util ?? 0) / 100, 0), 1))
            if frac > 0.005 {
                let arc = NSBezierPath()
                arc.appendArc(withCenter: c, radius: r, startAngle: 90, endAngle: 90 - 360 * frac, clockwise: true)
                arc.lineWidth = 2.2; arc.lineCapStyle = .round
                NSColor.black.setStroke(); arc.stroke()
            }
            if a.current {
                NSColor.black.setFill()
                NSBezierPath(ovalIn: NSRect(x: c.x - 2.2, y: c.y - 2.2, width: 4.4, height: 4.4)).fill()
            }
        }
        return true
    }
    img.isTemplate = true
    return img
}

// MARK: - 预览渲染（自检用）

/// 自检：有控件超出面板左右边界就报出来。真实面板里这样的内容会被裁掉，整页往一边歪
func reportOverflow(_ root: NSView, name: String) {
    let w = root.bounds.width
    func walk(_ v: NSView) {
        for s in v.subviews where !s.isHidden {
            let r = s.convert(s.bounds, to: root)
            if r.width > 0 && (r.minX < -0.5 || r.maxX > w + 0.5) {
                print("LAYOUT OVERFLOW in \(name): \(type(of: s)) x=\(Int(r.minX))…\(Int(r.maxX))，面板宽 \(Int(w))")
            }
            walk(s)
        }
    }
    walk(root)
}

func renderPNG<V: View>(_ view: V, _ path: String, dark: Bool) {
    let ap = NSAppearance(named: dark ? .darkAqua : .aqua)!
    // 和真实面板一样：NSHostingController 放进固定宽度、真正显示出来的面板（摆在屏幕外，看不见）。
    // 只用 NSHostingView 量「自然大小」时，分段控件之类的排版和真实面板不一样，内容超宽也看不出来
    let hc = NSHostingController(rootView: AnyView(view
        .background(dark ? Color(white: 0.16) : Color(white: 0.96))
        .environment(\.colorScheme, dark ? .dark : .light)))
    let win = NSPanel(contentRect: NSRect(x: -30000, y: -30000, width: panelWidth, height: 600),
                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    win.appearance = ap
    win.backgroundColor = dark ? NSColor(white: 0.17, alpha: 1) : NSColor(white: 0.95, alpha: 1)
    win.contentView = hc.view
    win.setFrame(NSRect(x: -30000, y: -30000, width: panelWidth, height: max(hc.view.fittingSize.height, 100)), display: false)
    win.orderFrontRegardless()
    let host = hc.view
    host.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    defer { win.orderOut(nil) }
    reportOverflow(host, name: (path as NSString).lastPathComponent)
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
    host.cacheDisplay(in: host.bounds, to: rep)
    // cacheDisplay 不画窗口背景，手动铺底色
    let out = NSImage(size: host.bounds.size)
    out.lockFocus()
    win.backgroundColor.setFill(); NSRect(origin: .zero, size: host.bounds.size).fill()
    rep.draw(in: NSRect(origin: .zero, size: host.bounds.size))
    out.unlockFocus()
    if let tiff = out.tiffRepresentation, let b = NSBitmapImageRep(data: tiff) {
        try? b.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}

// MARK: - 弹出面板：菜单栏下方留出间距的浮动窗口（不带箭头，类似控制中心）

let panelGap: CGFloat = 10        // 面板顶部离菜单栏的距离
let panelRadius: CGFloat = 14

final class FloatingPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isMovable = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    }
    override var canBecomeKey: Bool { true }     // 设置页里的输入框要能打字
}

final class PanelController: NSObject, NSWindowDelegate {
    let panel = FloatingPanel()
    let hosting: NSHostingController<RootView>
    weak var anchor: NSStatusBarButton?
    var monitors: [Any] = []
    var sizeObs: NSKeyValueObservation?
    var isShown: Bool { panel.isVisible }

    init(model: Model) {
        hosting = NSHostingController(rootView: RootView(m: model))
        super.init()
        if #available(macOS 13.0, *) { hosting.sizingOptions = [.preferredContentSize] }
        let bg = NSVisualEffectView()
        bg.material = .popover
        bg.blendingMode = .behindWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = panelRadius
        bg.layer?.cornerCurve = .continuous
        bg.layer?.masksToBounds = true
        bg.layer?.borderWidth = 0.5
        bg.layer?.borderColor = NSColor.separatorColor.cgColor
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(hosting.view)
        NSLayoutConstraint.activate([
            hosting.view.leadingAnchor.constraint(equalTo: bg.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
            hosting.view.topAnchor.constraint(equalTo: bg.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: bg.bottomAnchor),
        ])
        panel.contentView = bg
        panel.delegate = self
        // 主页 ↔ 设置页高度不同：内容变了就跟着改大小，顶部位置不动
        sizeObs = hosting.observe(\.preferredContentSize, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { if self?.isShown == true { self?.layout(animate: true) } }
        }
    }

    func contentSize() -> NSSize {
        let s = hosting.preferredContentSize
        return s.width > 10 && s.height > 10 ? s : hosting.view.fittingSize
    }

    func targetFrame() -> NSRect? {
        guard let b = anchor, let w = b.window else { return nil }
        let r = w.convertToScreen(b.convert(b.bounds, to: nil))
        let size = contentSize()
        let vis = (w.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        let top = min(r.minY, vis.maxY) - panelGap
        var x = r.midX - size.width / 2
        x = max(vis.minX + 8, min(x, vis.maxX - size.width - 8))
        return NSRect(x: x, y: top - size.height, width: size.width, height: size.height)
    }

    func layout(animate: Bool) {
        guard let f = targetFrame() else { return }
        panel.setFrame(f, display: true, animate: animate && panel.frame.height > 0)
        panel.invalidateShadow()
    }

    func show(from button: NSStatusBarButton) {
        anchor = button
        hosting.view.layoutSubtreeIfNeeded()
        guard let f = targetFrame() else { return }
        panel.setFrame(f.offsetBy(dx: 0, dy: 6), display: false)
        panel.alphaValue = 0
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(f, display: true)
        }
        panel.invalidateShadow()
        // 点面板外面、按 Esc 就收起
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in self?.close() } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] e in
            if e.keyCode == 53 { self?.close(); return nil }
            return e
        } as Any)
    }

    func close() {
        guard isShown else { return }
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.panel.orderOut(nil)
            self?.panel.alphaValue = 1
        })
    }

    func windowDidResignKey(_ notification: Notification) { close() }
}

// MARK: - App

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var item: NSStatusItem!
    let model = Model()
    var panel: PanelController!
    var timer: Timer?, queueTimer: Timer?
    var notifAuthorized = false
    var bag: Any?
    var resumeBusy = false
    var askedAX = false
    var ticks = 0

    func applicationDidFinishLaunching(_ n: Notification) {
        if dumpMode { dumpPreviews(); return }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = statusIcon([])
        item.button?.imagePosition = .imageLeft
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        item.button?.sendAction(on: [.leftMouseDown, .rightMouseDown])
        panel = PanelController(model: model)
        // 让命令行也能打开面板（自检 / 截图用）
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.cduo.togglePanel"), object: nil, queue: .main) { [weak self] _ in
            self?.togglePopover()
        }
        model.onSwitchError = { [weak self] msg in self?.post(title: "切换没有完成", body: msg, kind: "info", target: nil) }
        bag = model.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { self?.updateButton() } }
        setupNotifications()
        heartbeat()
        model.refresh(network: true)
        // 刚唤醒时网络和代理要过一会儿才恢复：30 秒后跑一轮（查额度、该预热的预热），别等后台的 5 分钟
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
                runCduo(["tick"]) { [weak self] _, _ in self?.model.refresh(network: false) }
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.heartbeat(); self.ticks += 1
            // 快用完 / 等刷新 / 有任务被打断时每分钟真查一次额度，平时交给后台每 5 分钟
            let due = self.model.waitUntil.map { $0 > 0 && $0 <= Date().timeIntervalSince1970 } ?? false
            if (self.model.hot && self.ticks % 2 == 0) || due {
                runCduo(["tick"]) { [weak self] _, _ in self?.model.refresh(network: false) }
            } else {
                self.model.refresh(network: false)
            }
        }
        queueTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.drainQueue(); self?.checkResume()
        }
    }

    @objc func togglePopover() {
        if panel.isShown { panel.close(); return }
        model.showSettings = false; model.confirmFor = nil
        model.refresh(network: false)
        panel.show(from: item.button!)
    }

    func updateButton() {
        guard let b = item?.button else { return }
        b.image = statusIcon(model.accts)
        var t: String
        if let to = model.switchingTo {
            t = model.switchPhase == "waiting" ? " 等回复结束…" : " 切换到 \(model.display(to))…"
        } else if !model.configured {
            t = " Cduo"
        } else {
            t = " " + (model.current?.util.map { String(format: "%.0f%%", $0) } ?? "—")
            if let e = model.etaSoon { t += " · \(hhmm(e))" }     // 预计 1 小时内用完：标题上直接显示时间
        }
        let attr = NSMutableAttributedString(string: t, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)])
        if model.actionable && model.switchingTo == nil {     // 只在需要你动手时亮橙点
            attr.append(NSAttributedString(string: " ●", attributes: [.foregroundColor: NSColor.systemOrange, .font: NSFont.systemFont(ofSize: 8)]))
        }
        b.attributedTitle = attr
    }

    // 通知
    func setupNotifications() {
        let c = UNUserNotificationCenter.current()
        c.delegate = self
        let sw = UNNotificationAction(identifier: "SWITCH", title: "切换", options: [])
        let later = UNNotificationAction(identifier: "LATER", title: "稍后", options: [])
        let open = UNNotificationAction(identifier: "OPEN", title: "打开会话", options: [.foreground])
        c.setNotificationCategories([UNNotificationCategory(identifier: "SUGGEST", actions: [sw, later], intentIdentifiers: [], options: []),
                                     UNNotificationCategory(identifier: "RESUME", actions: [open], intentIdentifiers: [], options: [])])
        c.requestAuthorization(options: [.alert, .sound]) { ok, _ in DispatchQueue.main.async { self.notifAuthorized = ok } }
    }

    func heartbeat() {
        try? FileManager.default.createDirectory(atPath: cduoDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: cduoDir + "/.menubar_alive", contents: Data())
    }

    func drainQueue() {
        let fm = FileManager.default
        var msgs: [[String: Any]] = []
        // 每条通知一个文件：cduo 先写临时文件（. 开头）再改名，这里只会读到写完整的文件，读一个删一个
        let dir = cduoDir + "/notify"
        if let names = try? fm.contentsOfDirectory(atPath: dir) {
            for n in names.sorted() where n.hasSuffix(".json") && !n.hasPrefix(".") {
                let p = dir + "/" + n
                if let d = fm.contents(atPath: p),
                   let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { msgs.append(j) }
                try? fm.removeItem(atPath: p)
            }
        }
        // 旧版 cduo 留下的队列文件：先改名再读，读的过程中就不会再有人往里追加
        let legacy = cduoDir + "/notify-queue.jsonl"
        if fm.fileExists(atPath: legacy) {
            let taken = legacy + ".draining"
            try? fm.removeItem(atPath: taken)
            if (try? fm.moveItem(atPath: legacy, toPath: taken)) != nil,
               let s = try? String(contentsOfFile: taken, encoding: .utf8) {
                for line in s.split(separator: "\n") {
                    if let d = line.data(using: .utf8),
                       let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { msgs.append(j) }
                }
            }
            try? fm.removeItem(atPath: taken)
        }
        guard !msgs.isEmpty else { return }
        for j in msgs {
            post(title: j["title"] as? String ?? "Cduo", body: j["msg"] as? String ?? "", kind: j["kind"] as? String ?? "info", target: j["target"] as? String)
        }
        model.refresh(network: false)
    }

    // MARK: 续上被额度打断的任务

    /// 队列文件里有到点的任务才去调 cduo（避免每 3 秒起一次 Python）
    func checkResume() {
        guard !resumeBusy else { return }
        let path = cduoDir + "/resume-queue.json"
        guard let d = FileManager.default.contents(atPath: path),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let items = j["items"] as? [[String: Any]] else { return }
        let nowT = Date().timeIntervalSince1970
        guard items.contains(where: { ($0["state"] as? String) == "pending" && ($0["not_before"] as? Double ?? 0) <= nowT }) else { return }
        guard NSRunningApplication.runningApplications(withBundleIdentifier: claudeBundleID).first?.isFinishedLaunching == true else { return }
        resumeBusy = true
        runCduo(["resume", "next"]) { [weak self] out, _ in
            guard let self = self else { return }
            guard let line = out.split(separator: "\n").last(where: { $0.hasPrefix("{") }),
                  let data = line.data(using: .utf8),
                  let it = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sid = it["session"] as? String, let msg = it["message"] as? String else { self.resumeBusy = false; return }
            self.model.refresh(network: false)
            self.performResume(session: sid, message: msg, title: it["title"] as? String ?? "")
        }
    }

    func performResume(session sid: String, message: String, title: String) {
        // note：没走到粘贴这一步的原因，会写进兜底通知里
        let finish: (String, String?) -> Void = { [weak self] act, note in
            runCduo(["resume", act, sid]) { out, _ in
                let r = (out.split(separator: "\n").last(where: { $0.hasPrefix("{") }).flatMap { $0.data(using: .utf8) })
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
                if (r["ok"] as? Bool) != true && (r["final"] as? Bool ?? true) {
                    self?.postResumeFallback(session: sid, message: message, title: title,
                                             sentTo: r["misdelivered_to"] as? String, note: note)
                }
                self?.resumeBusy = false
                self?.model.refresh(network: false)
            }
        }
        guard AXIsProcessTrusted() else {
            if !askedAX { askedAX = true; requestAccessibility() }   // 第一次需要时请你授权一次
            finish("manual", "Cduo 没有「辅助功能」授权，没法替你发送（升级后系统会作废旧授权）。在 Cduo 面板上点「去授权」就能恢复自动续上。")
            return
        }
        guard userIdleSeconds() >= 5 else { finish("defer", nil); return }   // 你正在用电脑，晚点再试
        NSWorkspace.shared.open(URL(string: "claude://code/continue?session=\(sid)")!)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier != claudeBundleID {
                NSRunningApplication.runningApplications(withBundleIdentifier: claudeBundleID).first?.activate()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == claudeBundleID,
                      userIdleSeconds() >= 3 else { finish("defer", nil); return }
                // 会话链接没跳过去时，前台开着的是别的会话：标题对不上就不粘贴
                let wt = claudeWindowTitle()
                guard windowMatchesSession(wt, sessionTitle: title) else {
                    NSLog("Cduo resume: window title %@ does not match session %@, not pasting", wt ?? "", title)
                    finish("manual", "没能确认 Claude 打开的就是这个会话，为免发错没有自动发送。")
                    return
                }
                let pb = NSPasteboard.general
                let saved = savePasteboard(pb)
                pb.clearContents(); pb.setString(message, forType: .string)
                let ours = pb.changeCount
                postKey(9, command: true)                     // ⌘V
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    postKey(36)                               // 回车发送
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        // 这期间你又复制了别的东西，就不去覆盖它
                        if pb.changeCount == ours { restorePasteboard(pb, saved) }
                    }
                    // 发送后核对一次；没对上就通知你手动处理，不再自动重试（免得重复发、发错地方）
                    DispatchQueue.main.asyncAfter(deadline: .now() + 6) { finish("check", nil) }
                }
            }
        }
    }

    func postResumeFallback(session sid: String, message: String, title: String, sentTo: String? = nil, note: String? = nil) {
        let name = title.isEmpty ? "会话" : title
        let c = UNMutableNotificationContent()
        if let wrong = sentTo {
            c.title = "续上的话可能发错了会话"
            c.body = "它出现在了「\(wrong)」里，请去看一眼。「\(name)」还没续上：点这里打开它，续上的话已经复制好，粘贴发送即可。"
        } else {
            c.title = "续上被额度打断的任务"
            c.body = (note.map { $0 + "\n" } ?? "") + "点这里打开「\(name)」，续上的话已经复制好，粘贴发送即可。"
        }
        c.categoryIdentifier = "RESUME"
        c.userInfo = ["session": sid, "message": message]
        if notifAuthorized {
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
        } else {
            post(title: c.title, body: sentTo == nil ? "打开「\(name)」发一句「继续」即可" : c.body, kind: "info", target: nil)
        }
    }

    func post(title: String, body: String, kind: String, target: String?) {
        let quiet = kind.hasSuffix("_quiet")
        if !notifAuthorized {
            if quiet { return }      // 系统通知没法做成不打扰的样子：安静的提醒就不发了
            let esc = { (s: String) in s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", "display notification \"\(esc(body))\" with title \"\(esc(title))\""]
            try? p.run(); return
        }
        let c = UNMutableNotificationContent()
        c.title = title; c.body = body
        if kind.hasPrefix("suggest"), let t = target { c.categoryIdentifier = "SUGGEST"; c.userInfo = ["target": t] }
        if quiet { c.interruptionLevel = .passive }   // 不响铃、不弹横幅，只进通知中心
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // 安静的提醒只进通知中心，不弹横幅
        completionHandler(notification.request.content.interruptionLevel == .passive ? [.list] : [.banner, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        if let sid = info["session"] as? String, response.actionIdentifier != UNNotificationDismissActionIdentifier {
            DispatchQueue.main.async {
                if let msg = info["message"] as? String {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(msg, forType: .string)
                }
                NSWorkspace.shared.open(URL(string: "claude://code/continue?session=\(sid)")!)
            }
        } else if let t = info["target"] as? String,
           response.actionIdentifier == "SWITCH" || response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            DispatchQueue.main.async { self.model.startSwitch(t) }
        }
        completionHandler()
    }

    // 自检：把面板渲染成 PNG
    func dumpPreviews() {
        model.refreshSync()
        print("accounts:", model.accts.map { "\($0.display) \($0.util.map { String(format: "%.0f", $0) } ?? "?")%" })
        print("events:", model.events.map { "\(hhmm($0.time)) \($0.text)" })
        if let dir = previewDir {
            dumpStatusIcon(model.accts, "\(dir)/statusicon.png")
            for dark in [false, true] {
                let s = dark ? "dark" : "light"
                renderPNG(MainView(m: model), "\(dir)/main-\(s).png", dark: dark)
                renderPNG(SettingsView(m: model), "\(dir)/settings-\(s).png", dark: dark)
                if let r = model.accts.first(where: { !$0.current }) {      // 「移除」确认打开的样子
                    renderPNG(SettingsView(m: model, removing: r.name, purge: true), "\(dir)/settings-remove-\(s).png", dark: dark)
                }
                let sw = Model(); sw.apply(runCduoSync(["status", "--json", "--cached"]).0)
                sw.recAction = "switch"; sw.recTarget = sw.accts.first(where: { !$0.current })?.name; sw.recReason = "当前号已用 96%"
                if let i = sw.accts.firstIndex(where: { $0.current }) { sw.accts[i].util = 96; sw.accts[i].running = true }
                renderPNG(MainView(m: sw), "\(dir)/suggest-\(s).png", dark: dark)
                let nl = Model(); nl.apply(runCduoSync(["status", "--json", "--cached"]).0)
                if let c = nl.accts.firstIndex(where: { $0.current }), let o = nl.accts.firstIndex(where: { !$0.current }) {
                    nl.accts[c].util = 99; nl.accts[o].util = 21; nl.accts[o].hasProfile = false
                    nl.recAction = "need_login"; nl.recTarget = nl.accts[o].name
                    nl.recReason = "\(nl.accts[o].display) 还有额度，但还没在桌面版登录过。点它卡片上的「登录桌面版」，登录一次以后就能一键切换"
                }
                renderPNG(MainView(m: nl), "\(dir)/needlogin-\(s).png", dark: dark)
                let wt = Model(); wt.apply(runCduoSync(["status", "--json", "--cached"]).0)
                wt.mode = "idle"; wt.recAction = "wait"; wt.waitUntil = Date().timeIntervalSince1970 + 3000; wt.waitCount = 1
                for i in wt.accts.indices { wt.accts[i].util = 100; wt.accts[i].running = true }
                renderPNG(MainView(m: wt), "\(dir)/wait-\(s).png", dark: dark)
            }
            print("previews written")
        }
        exit(0)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
