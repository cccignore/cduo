// Cduo 菜单栏 App（SwiftUI 弹出面板）：两个 Claude 号的额度、一键切换、全部设置。
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

func openInTerminal(_ cmd: String) {
    let path = cduoDir + "/run.command"
    let script = "#!/bin/zsh -l\nclear\n\(cmd)\necho\nread -k1 \"?完成。按任意键关闭此窗口…\"\n"
    try? script.write(toFile: path, atomically: true, encoding: .utf8)
    chmod(path, 0o755)
    NSWorkspace.shared.open(URL(fileURLWithPath: path))
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

// MARK: - 数据模型

struct Acct: Identifiable, Equatable {
    var id: String { name }
    var name = "", label = "", email = ""
    var util: Double? = nil, running = false, resetsAt: Double? = nil
    var error: String? = nil, hasProfile = false, current = false
    var display: String { label.isEmpty ? name : label }
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
    var onSwitchError: ((String) -> Void)?

    /// 当前号快用完、正在等刷新、或有被打断的任务：查得勤一点
    var hot: Bool { (current?.util ?? 0) >= 85 || waitUntil != nil || !interrupted.isEmpty }

    func display(_ n: String?) -> String {
        guard let n = n else { return "?" }
        return accts.first(where: { $0.name == n })?.display ?? n
    }

    var current: Acct? { accts.first(where: { $0.current }) }

    var events: [Event] {
        var ev: [Event] = []
        for a in accts where a.running {
            if let r = a.resetsAt { ev.append(Event(time: r, icon: "arrow.clockwise", text: "\(a.display) 额度刷新")) }
        }
        if prewarm, let at = nextAt, let n = nextName {
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
            Acct(name: $0["name"] as? String ?? "?", label: $0["label"] as? String ?? "",
                 email: $0["email"] as? String ?? "",
                 util: $0["util"] as? Double, running: $0["running"] as? Bool ?? false,
                 resetsAt: $0["resets_at"] as? Double, error: $0["error"] as? String,
                 hasProfile: $0["has_profile"] as? Bool ?? false, current: $0["desktop_current"] as? Bool ?? false)
        }
        configured = !accts.isEmpty
        version = j["version"] as? String ?? ""
        let rec = j["recommend"] as? [String: Any] ?? [:]
        recAction = rec["action"] as? String ?? ""
        recTarget = rec["target"] as? String
        recReason = rec["reason"] as? String ?? ""
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
    var recommended: Bool { m.recAction == "switch" && m.recTarget == a.name }

    var subtitle: String {
        if a.util == nil { return "额度读取失败" }
        return a.running ? "\(hhmm(a.resetsAt)) 刷新" : "满额 · 未开始计时"
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text(a.display).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 4)
                if a.current { Pill(text: "使用中") }
                else if recommended { Pill(text: "推荐", color: .orange) }
            }
            Ring(util: a.util, size: 78)
            Text(subtitle).font(.system(size: 11)).foregroundColor(a.util == nil ? .orange : .secondary)
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
            Button("重新登录") { openInTerminal("cduo login \(a.name)") }
                .buttonStyle(.bordered).controlSize(.small)
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
        } else if a.hasProfile {
            if recommended {
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
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundColor(color).font(.system(size: 13, weight: .semibold))
            Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
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
    var modeName: String { ["off": "手动", "notify": "提醒我", "idle": "全自动"][m.mode] ?? "提醒我" }

    var body: some View {
        VStack(spacing: 14) {
            header
            if !m.configured && m.loaded { welcome }
            else {
                HStack(spacing: 10) { ForEach(m.accts.prefix(2)) { a in AccountCard(m: m, a: a) } }
                status
                if !m.events.isEmpty { upcoming }
            }
        }
        .padding(16)
        .frame(width: panelWidth)
    }

    var header: some View {
        HStack(spacing: 10) {
            Logo(size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text("Cduo").font(.system(size: 14, weight: .bold))
                Text(m.configured ? "\(modeName) · 两个号错峰使用" : "两个 Claude 号，额度不浪费")
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
        } else if let w = m.waitUntil {
            Banner(icon: "hourglass",
                   text: "两个号都用完了。" + (w > 0 ? "\(hhmm(w)) 有号刷新后自动换过去" : "等额度刷新后自动换过去")
                       + (m.waitCount > 0 && m.autoResume ? "，并续上 \(m.waitCount) 个被打断的任务" : ""),
                   color: .red)
        } else if !m.interrupted.isEmpty && m.mode != "idle" && m.recAction == "switch" {
            Banner(icon: "exclamationmark.circle.fill",
                   text: "任务「\(m.interrupted[0])」被额度打断了。切到 \(m.display(m.recTarget)) 后" + (m.autoResume ? "会自动续上" : "发一句「继续」即可"),
                   color: .orange)
        } else if m.recAction == "switch" {
            Banner(icon: "lightbulb.fill", text: "建议切到 \(m.display(m.recTarget))：\(m.recReason)", color: .orange)
        } else if m.recAction == "wait" {
            Banner(icon: "hourglass", text: m.recReason, color: .red)
        } else if !m.prewarm {
            Banner(icon: "pause.circle", text: "自动提前计时已关闭，两个号的刷新时间不会自动错开", color: .gray)
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
            Text("设置向导会带你登录两个号，大约 5 分钟。过程中 Claude 会重启几次。")
                .font(.system(size: 12)).foregroundColor(.secondary).multilineTextAlignment(.center)
            Button { openInTerminal("cduo setup") } label: { Text("开始设置").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent).controlSize(.large)
        }
        .padding(.vertical, 10)
    }
}

// MARK: - 设置面板

struct SettingsView: View {
    @ObservedObject var m: Model
    @State private var names: [String: String] = [:]

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
                            Text("手动").tag("off"); Text("提醒我").tag("notify"); Text("全自动").tag("idle")
                        }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: .infinity)
                        Text(["off": "只显示额度，不打扰你。",
                              "notify": "该换号时发通知，点通知上的「切换」即可。",
                              "idle": "用完才换号，一点不浪费。两个号都用完时，等先刷新的那个。"][m.mode] ?? "")
                            .font(.system(size: 11)).foregroundColor(.secondary).frame(maxWidth: .infinity, alignment: .leading)
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
                        row("开启", note: "两个号错开 2.5 小时刷新额度") {
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
                            }
                        }
                        Text("改完名字按回车保存；▶︎ 让这个号立刻开始计时。")
                            .font(.system(size: 11)).foregroundColor(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    group("通用") {
                        row("开机自动启动") {
                            toggle({ m.loginItem }, { v in m.loginItem = v; runCduo(["agents", v ? "login-on" : "login-off"]) { _, _ in m.refresh(network: false) } })
                        }
                        HStack(spacing: 8) {
                            tool("同步会话", "arrow.triangle.2.circlepath") { runCduo(["sync"]) }
                            tool("自检", "stethoscope") { openInTerminal("cduo doctor") }
                            tool("设置向导", "wand.and.stars") { openInTerminal("cduo setup") }
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

// MARK: - 菜单栏图标：两个圆环，弧长=已用额度，正在用的号中间有实心点

func statusIcon(_ accts: [Acct]) -> NSImage {
    let list = accts.isEmpty ? [Acct(), Acct()] : Array(accts.prefix(2))
    let w: CGFloat = list.count > 1 ? 31 : 17
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

func renderPNG<V: View>(_ view: V, _ path: String, dark: Bool) {
    let ap = NSAppearance(named: dark ? .darkAqua : .aqua)!
    let host = NSHostingView(rootView: view
        .background(dark ? Color(white: 0.16) : Color(white: 0.96))
        .environment(\.colorScheme, dark ? .dark : .light))
    host.appearance = ap
    host.frame = NSRect(origin: .zero, size: host.fittingSize)
    let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    win.appearance = ap
    win.backgroundColor = dark ? NSColor(white: 0.17, alpha: 1) : NSColor(white: 0.95, alpha: 1)
    win.contentView = host
    host.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.4))
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

// MARK: - App

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var item: NSStatusItem!
    let model = Model()
    let popover = NSPopover()
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
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(rootView: RootView(m: model))
        model.onSwitchError = { [weak self] msg in self?.post(title: "切换没有完成", body: msg, kind: "info", target: nil) }
        bag = model.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { self?.updateButton() } }
        setupNotifications()
        heartbeat()
        model.refresh(network: true)
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
        if popover.isShown { popover.performClose(nil); return }
        model.showSettings = false; model.confirmFor = nil
        model.refresh(network: false)
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: item.button!.bounds, of: item.button!, preferredEdge: .minY)
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
        }
        let attr = NSMutableAttributedString(string: t, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)])
        if model.recAction == "switch" && model.switchingTo == nil {
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
        let q = cduoDir + "/notify-queue.jsonl"
        guard FileManager.default.fileExists(atPath: q), let s = try? String(contentsOfFile: q, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(atPath: q)
        for line in s.split(separator: "\n") {
            guard let d = line.data(using: .utf8), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
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
        let finish: (String) -> Void = { [weak self] act in
            runCduo(["resume", act, sid]) { out, _ in
                let r = (out.split(separator: "\n").last(where: { $0.hasPrefix("{") }).flatMap { $0.data(using: .utf8) })
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
                if (r["ok"] as? Bool) != true && (r["final"] as? Bool ?? true) {
                    self?.postResumeFallback(session: sid, message: message, title: title)
                }
                self?.resumeBusy = false
                self?.model.refresh(network: false)
            }
        }
        guard AXIsProcessTrusted() else {
            if !askedAX { askedAX = true; requestAccessibility() }   // 第一次需要时请你授权一次
            finish("manual"); return
        }
        guard userIdleSeconds() >= 5 else { finish("defer"); return }   // 你正在用电脑，晚点再试
        NSWorkspace.shared.open(URL(string: "claude://code/continue?session=\(sid)")!)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier != claudeBundleID {
                NSRunningApplication.runningApplications(withBundleIdentifier: claudeBundleID).first?.activate()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == claudeBundleID,
                      userIdleSeconds() >= 3 else { finish("defer"); return }
                let pb = NSPasteboard.general
                let old = pb.string(forType: .string)
                pb.clearContents(); pb.setString(message, forType: .string)
                postKey(9, command: true)                     // ⌘V
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    postKey(36)                               // 回车发送
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        pb.clearContents(); if let o = old { pb.setString(o, forType: .string) }
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 6) { finish("check") }
                }
            }
        }
    }

    func postResumeFallback(session sid: String, message: String, title: String) {
        let c = UNMutableNotificationContent()
        c.title = "续上被额度打断的任务"
        c.body = "点这里打开「\(title.isEmpty ? "会话" : title)」，续上的话已经复制好，粘贴发送即可。"
        c.categoryIdentifier = "RESUME"
        c.userInfo = ["session": sid, "message": message]
        if notifAuthorized {
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
        } else {
            post(title: c.title, body: "打开「\(title)」发一句「继续」即可", kind: "info", target: nil)
        }
    }

    func post(title: String, body: String, kind: String, target: String?) {
        if !notifAuthorized {
            let esc = { (s: String) in s.replacingOccurrences(of: "\"", with: "\\\"") }
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", "display notification \"\(esc(body))\" with title \"\(esc(title))\""]
            try? p.run(); return
        }
        let c = UNMutableNotificationContent()
        c.title = title; c.body = body
        if kind == "suggest", let t = target { c.categoryIdentifier = "SUGGEST"; c.userInfo = ["target": t] }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
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
            for dark in [false, true] {
                let s = dark ? "dark" : "light"
                renderPNG(MainView(m: model), "\(dir)/main-\(s).png", dark: dark)
                renderPNG(SettingsView(m: model), "\(dir)/settings-\(s).png", dark: dark)
                let sw = Model(); sw.apply(runCduoSync(["status", "--json", "--cached"]).0)
                sw.recAction = "switch"; sw.recTarget = sw.accts.first(where: { !$0.current })?.name; sw.recReason = "当前号已用 96%"
                if let i = sw.accts.firstIndex(where: { $0.current }) { sw.accts[i].util = 96; sw.accts[i].running = true }
                renderPNG(MainView(m: sw), "\(dir)/suggest-\(s).png", dark: dark)
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
