"""体验改进的测试：提醒分级、错误分类与过期数据、预热可靠性、周额度、用完时间预测、暂停预热与彻底清除。
全部用假数据，不碰真实账号、钥匙串和桌面版。

运行：python3 tests/test_ux.py
"""
import os, sys, json, time, pathlib, shutil, tempfile, io, contextlib, socket, urllib.error
import datetime as dt, importlib.util, importlib.machinery

SRC = sys.argv[1] if len(sys.argv) > 1 else str(pathlib.Path(__file__).resolve().parent.parent / "cduo")
T = pathlib.Path(tempfile.mkdtemp(prefix="cduo-ux-"))
H = T/"home"; AS = T/"appsupport"; PR = T/"projects"
for d in (H, AS, PR): d.mkdir(parents=True)
for k in ("CLAUDE_CODE_ENTRYPOINT", "__CFBundleIdentifier", "CLAUDE_CODE_ORGANIZATION_UUID"):
    os.environ.pop(k, None)
os.environ.update(CDUO_HOME=str(H), CDUO_APP_SUPPORT=str(AS), CDUO_FAKE_DESKTOP="1", CDUO_DRY_PING="1",
                  CDUO_NO_NOTIFY="1", CDUO_RESUME_CHECK_WAIT="0")
ld = importlib.machinery.SourceFileLoader("cduo", SRC); spec = importlib.util.spec_from_loader("cduo", ld)
m = importlib.util.module_from_spec(spec); ld.exec_module(m)

FAILS = []
def ok(c, msg):
    print(("PASS " if c else "FAIL ") + msg)
    if not c: FAILS.append(msg)

class NS:
    def __init__(self, **kw): self.__dict__.update(kw)

def capture(fn, *a, **k):
    out, err, exited = io.StringIO(), io.StringIO(), False
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        try:
            fn(*a, **k)
        except SystemExit:
            exited = True
    return exited, out.getvalue(), err.getvalue()

MIN = 60
ORG = "cccccccc-0000-0000-0000-000000000003"
UUID = {n: f"{c * 8}-0000-0000-0000-00000000000{i}" for i, (n, c) in enumerate((("A", "a"), ("B", "b"), ("C", "c")), 1)}
cfg = json.loads(json.dumps(m.DEFAULT_CONFIG))
cfg["projects_dirs"] = [str(PR)]
cfg["accounts"] = [{"name": n, "label": n, "account_uuid": u, "org_uuid": ORG, "cli_dir": str(m.CLIROOT / n), "owned": True}
                   for n, u in UUID.items()]
m.save_config(cfg)
for n in UUID:
    (m.CLIROOT / n).mkdir(parents=True)
    (m.CLIROOT / n / ".credentials.json").write_text(json.dumps({"claudeAiOauth": {
        "accessToken": "tok" + n, "refreshToken": "r" + n, "expiresAt": int((time.time() + 3600) * 1000)}}))
    (H/"desktop"/n).mkdir(parents=True); (H/"desktop"/n/"oauth.json").write_text("{}")

def U(util, resets_in=None, **kw):
    d = {"ok": True, "no5h": False, "util": util, "fetched": time.time(), "error": None,
         "resets_at": time.time() + resets_in if resets_in is not None else None}
    d.update(kw)
    return d

def http_error(code, retry_after=None):
    return urllib.error.HTTPError("https://x", code, "x", {"Retry-After": str(retry_after)} if retry_after else {}, None)

# ───── 1. 错误分类：只有登录问题才让人去「重新登录」 ─────
cases = [(http_error(401), "login"), (http_error(400), "login"), (http_error(403), "denied"), (http_error(429), "ratelimit"),
         (http_error(503), "server"), (urllib.error.URLError("EOF occurred in violation of protocol (_ssl.c:1129)"), "network"),
         (socket.timeout("timed out"), "network"), (ConnectionRefusedError(61, "refused"), "network"), (KeyError("x"), "other")]
ok(all(m.classify_error(e)[1] == k for e, k in cases), "errors are classified: login / denied / ratelimit / server / network / other")

real_http = m.http_json
def raise_(e):
    def f(*a, **k): raise e
    return f
m.http_json = raise_(http_error(429, 120))
u = m.fetch_account_usage(cfg, cfg["accounts"][0])
ok(u["error_kind"] == "ratelimit" and 110 < u["retry_at"] - time.time() < 130, "429 → ratelimit, retry after the server's Retry-After")
m.http_json = raise_(urllib.error.URLError("EOF occurred in violation of protocol"))
u = m.fetch_account_usage(cfg, cfg["accounts"][0])
ok(u["error_kind"] == "network", f"usage call fails at the network → network ({u['error']})")
(m.CLIROOT/"C"/".credentials.json").rename(m.CLIROOT/"C"/".credentials.bak")
real_creds = m.read_creds
m.read_creds = lambda d: real_creds(d) if not d.endswith("/C") else (None, None)
u = m.fetch_account_usage(cfg, cfg["accounts"][2])
ok(u["error_kind"] == "login", "no CLI login → login (the only case that offers 「重新登录」)")
m.read_creds = real_creds
(m.CLIROOT/"C"/".credentials.bak").rename(m.CLIROOT/"C"/".credentials.json")

# ───── 2. 断网：保留上次读数、标出时间，预热暂停 ─────
pings = []
m.do_ping = lambda c, a, why: pings.append(a["name"]) or True
m.in_active_hours = lambda c, t=None: True
m.desktop_org_hint = lambda: None
m.sync_sessions = lambda *a, **k: {}
m.current_desktop_profile = lambda c, s: "A"
usage = {"A": U(62, 2 * 3600), "B": U(10, 3 * 3600), "C": U(5, 4 * 3600)}
calls = {"n": 0}
def fake_fetch(c, a):
    calls["n"] += 1
    v = usage[a["name"]]
    return dict(v) if isinstance(v, dict) else v(a)
m.fetch_account_usage = fake_fetch
cfgn = dict(cfg, auto_switch="notify", prewarm_enabled=True)
m.save_state({"accounts": {}, "desktop_current": "A"})
m.tick(cfgn)
def down(a):
    return {"fetched": time.time(), "ok": False, "util": None, "resets_at": None, "no5h": False,
            "error": "网络/代理连不上（URLError）", "error_kind": "network"}
for n in usage: usage[n] = down
st = m.tick(cfgn)                                        # 第一轮读不到：代理偶尔掐断一次连接
exited, out, err = capture(m.cmd_status, NS(json=True, cached=True), cfgn)
j = json.loads(out); cA = j["accounts"][0]
ok(not st.get("net_down_since") and st["accounts"]["A"]["fails"] == 1 and cA["error_kind"] is None
   and cA["util"] == 62 and cA["running"] and cA["stale_util"] is None and not j["net_down_since"],
   "one failed read → no banner, the card keeps showing 62% as usual")
st = m.tick(cfgn)                                        # 连续第二轮也读不到：真的断网了
ok(st.get("net_down_since") and st["accounts"]["A"]["stale_util"] == 62 and st["accounts"]["A"]["fails"] == 2,
   "two failed reads in a row → network down: keep the last reading (62%) and note since when")
exited, out, err = capture(m.cmd_status, NS(json=True, cached=True), cfgn)
j = json.loads(out); cA = j["accounts"][0]
ok(cA["error_kind"] == "network" and cA["stale_util"] == 62 and cA["util"] is None and cA["ok_at"] and j["net_down_since"],
   "status JSON: error_kind=network, stale_util, ok_at, net_down_since")
ok("网络/代理连不上" in st["next_ping"]["why"], f"prewarm says it's waiting for the network: {st['next_ping']['why']}")
ok(m.est_resets(st["accounts"]["A"]) == st["accounts"]["A"]["stale_resets_at"], "planning uses the last known reset time, not 「idle」")
m.save_state({"accounts": {"A": U(62, 2 * 3600), "B": U(0, None), "C": U(0, None)}, "desktop_current": "A"})
for n in usage: usage[n] = down                          # B、C 上次读到时是空闲的、按理该预热了……
n_before = len(pings)
st2 = m.tick(cfgn)
ok(len(pings) == n_before and not st2.get("net_down_since"),
   "…a first failed round pings nothing (no account read OK this round) and shows no banner yet")
st2 = m.tick(cfgn)
ok(len(pings) == n_before and st2.get("net_down_since"), "…a second failed round shows the banner, still nothing pinged")
usage.update(A=U(63, 2 * 3600), B=U(10, 3 * 3600), C=U(5, 4 * 3600))
st = m.tick(cfgn)
ok(not st.get("net_down_since") and st["accounts"]["A"]["ok"] and st["accounts"]["A"]["fails"] == 0,
   "network back → banner cleared, failure count reset")

# ───── 2b. 偶发的一次失败：请求自己重试；还是失败也先不报，连续两次才报 ─────
import http.client
def opener_with(results, calls):
    class O:
        def open(self, req, timeout=None):
            calls.append(req.get_method())
            r = results.pop(0)
            if isinstance(r, BaseException):
                raise r
            return io.BytesIO(json.dumps(r).encode())
    return O()
saved = (m.urllib.request.build_opener, m.proxy_url, m.claude_version, m.HTTP_RETRY_WAIT)
m.proxy_url = lambda c: None; m.claude_version = lambda c: "1.0.0"; m.HTTP_RETRY_WAIT = (0, 0)
eof = urllib.error.URLError("EOF occurred in violation of protocol (_ssl.c:1129)")
def try_http(results, data=None):
    calls = []
    o = opener_with(list(results), calls)
    m.urllib.request.build_opener = lambda *a: o
    try:
        return real_http(cfg, "https://x", data=data), calls
    except Exception as e:
        return e, calls
r, hc = try_http([eof, ConnectionResetError(54, "reset"), {"ok": 1}])
ok(r == {"ok": 1} and hc == ["GET"] * 3, "a GET the proxy drops is retried (up to twice) and then succeeds")
r, hc = try_http([http.client.IncompleteRead(b""), {"ok": 1}])
ok(r == {"ok": 1} and len(hc) == 2, "a connection cut mid-response is retried too")
r, hc = try_http([eof, eof, eof, {"ok": 1}])
ok(isinstance(r, urllib.error.URLError) and len(hc) == 3, "…but it gives up after 3 tries")
r, hc = try_http([http_error(401), {"ok": 1}])
ok(isinstance(r, urllib.error.HTTPError) and len(hc) == 1, "an HTTP error from the server isn't retried")
r1, hc1 = try_http([socket.timeout("timed out"), {"ok": 1}])
r2, hc2 = try_http([urllib.error.URLError(socket.timeout("timed out")), {"ok": 1}])
ok(isinstance(r1, OSError) and isinstance(r2, urllib.error.URLError) and len(hc1) == len(hc2) == 1,
   "a timeout isn't retried (it already waited; retrying would only make an outage slower)")
r, hc = try_http([eof, {"ok": 1}], data={"grant_type": "refresh_token"})
ok(isinstance(r, urllib.error.URLError) and hc == ["POST"],
   "a POST (token refresh) isn't retried: the server may already have rotated the token")
m.urllib.request.build_opener, m.proxy_url, m.claude_version, m.HTTP_RETRY_WAIT = saved

def neterr(kind="network"):
    return {"fetched": time.time(), "ok": False, "util": None, "resets_at": None, "no5h": False,
            "error": "网络/代理连不上（URLError）" if kind == "network" else "凭据过期/未登录", "error_kind": kind}
p = m.carry_stale({}, U(40, 3600))
u1 = m.carry_stale(p, neterr())
v = m.as_shown(u1)
ok(u1["fails"] == 1 and m.soft_fail(u1) and v["ok"] and m.effective_util(v) == 40 and m.window_running(v)
   and v["error_kind"] is None and not u1["ok"],
   "one failed read right after a good one → shown as the last reading (40%), no error (the saved state stays honest)")
u2 = m.carry_stale(u1, neterr())
ok(u2["fails"] == 2 and not m.soft_fail(u2) and not m.as_shown(u2).get("ok"), "two in a row → the error is shown")
pi = m.carry_stale({}, U(0, None))                       # 空闲（满额）的号
vi = m.as_shown(m.carry_stale(pi, neterr()))
ok(vi.get("ok") and m.effective_util(vi) == 0 and not m.shown_resets(vi), "an idle account's one failed read → still shown as full")
ok(not m.soft_fail(m.carry_stale(p, neterr("login"))), "a login error is shown the first time (it needs the user)")
old = dict(p, ok_at=time.time() - 20 * MIN)
ok(not m.soft_fail(m.carry_stale(old, neterr())), "a failed read whose last good one is 20 min old (e.g. just after sleep) is shown")
ok(not m.soft_fail(m.carry_stale({}, neterr())), "a first-ever read that fails is shown")
ok(m.carry_stale(u1, U(41, 3600))["fails"] == 0, "a good read resets the count")
m.save_state({"accounts": {"A": u1, "B": U(10, 3 * 3600), "C": U(5, 4 * 3600)}, "desktop_current": "A"})
exited, out, err = capture(m.cmd_status, NS(json=False, cached=True), cfgn)
ok("已用  40%" in out and "网络/代理连不上" not in out, "the text status shows it as normal too")
base = {"A": m.carry_stale({}, U(62, 2 * 3600)), "B": m.carry_stale({}, U(10, 60 * MIN)), "C": m.carry_stale({}, U(5, 4 * 3600))}
r0 = m.recommend(cfgn, {"accounts": base, "desktop_current": "A"})
r1 = m.recommend(cfgn, {"accounts": dict(base, B=m.carry_stale(base["B"], neterr())), "desktop_current": "A"})
ok((r0["kind"], r0["target"]) == ("expiring", "B") and (r1["kind"], r1["target"]) == (r0["kind"], r0["target"]),
   f"one failed read of B doesn't change the suggestion ({r0['kind']} {r0['target']} → {r1['kind']} {r1['target']})")
t0 = m.pick_target(cfgn, {"accounts": base}, exclude="A")
t1 = m.pick_target(cfgn, {"accounts": dict(base, B=m.carry_stale(base["B"], neterr()))}, exclude="A")
ok(t0 == t1 == "B", f"…nor the auto-switch target ({t0} → {t1})")

# ───── 3. 限流：在服务器要求的时间之前不再查这个号 ─────
m.update_state(lambda s: s["accounts"]["B"].update(retry_at=time.time() + 600, ok=False, error_kind="ratelimit"))
calls["n"] = 0
st = m.tick(cfgn)
ok(calls["n"] == 2 and st["accounts"]["B"].get("error_kind") == "ratelimit", f"rate-limited account isn't fetched again yet ({calls['n']} fetches for 3 accounts)")
m.update_state(lambda s: s["accounts"]["B"].pop("retry_at", None))

# ───── 4. 预热：一个号发不了就试下一个；失败按类型决定等多久 ─────
old_start = time.time() - 4 * 3600                       # A 的窗口 4 小时前开始：B、C 都该开始了
usage.update(A=U(40, 3600), B=U(0, None), C=U(0, None))
def set_ping(name, ok_, kind, ago):
    m.update_state(lambda s: s["accounts"].setdefault(name, {}).update(last_ping=time.time() - ago, last_ping_ok=ok_,
                                                                         last_ping_kind=kind))
m.save_state({"accounts": {}, "desktop_current": "A"})
set_ping("B", False, "other", 5 * MIN)                 # B 5 分钟前失败（非网络原因）：要等 1 小时
pings.clear(); m.tick(cfgn)
ok(pings == ["C"], f"B is still waiting after a failure → C goes instead of nobody: {pings}")
m.save_state({"accounts": {}, "desktop_current": "A"})
set_ping("B", False, "network", 11 * MIN)              # 网络类失败，11 分钟前：可以重试了
pings.clear(); m.tick(cfgn)
ok(pings == ["B"], f"a network failure is retried after 10 minutes, not 60: {pings}")
m.save_state({"accounts": {}, "desktop_current": "A"})
usage["B"] = {"fetched": time.time(), "ok": False, "util": None, "resets_at": None, "error": "未登录", "error_kind": "login"}
pings.clear(); m.tick(cfgn)
ok(pings == ["C"], f"an account whose login is broken isn't pinged (it would only fail): {pings}")
usage["B"] = U(0, None, weekly_util=85.0)
m.save_state({"accounts": {}, "desktop_current": "A"})
pings.clear(); m.tick(cfgn)
ok(pings == ["C"], f"an account whose weekly quota is tight (85%) isn't warmed up: {pings}")
ok(m._ping_error_kind('{"api_error_status":403,"result":"Failed to authenticate. API Error: 403 Request not allowed"}') == "denied"
   and m._ping_error_kind('"result":"Not logged in · Please run /login"') == "login"
   and m._ping_error_kind("TypeError: fetch failed ETIMEDOUT") == "network"
   and m._ping_error_kind("something else") == "other", "warm-up failures are classified from claude's output")
def failing_ping(c, a, why):
    m._PING_ERR[a["name"]] = "denied"; pings.append(a["name"]); return False
m.do_ping = failing_ping
usage["B"] = U(0, None)
m.save_state({"accounts": {}, "desktop_current": "A"})
pings.clear(); st = m.tick(cfgn)
exited, out, err = capture(m.cmd_status, NS(json=True, cached=True), cfgn)
cB = next(x for x in json.loads(out)["accounts"] if x["name"] == "B")
ok(st["accounts"]["B"]["last_ping_kind"] == "denied" and cB["ping_fail"]["kind"] == "denied"
   and 9 * MIN < cB["ping_fail"]["retry_at"] - time.time() <= 10 * MIN, "a failed warm-up shows on the card with its reason and retry time")
ok(st["next_ping"]["name"] == "C" and st["next_ping"]["at"] <= time.time() and "先轮到它" in st["next_ping"]["why"],
   f"「接下来」 shows C (it goes next round), with a matching reason: {st['next_ping']['why']}")
exited, out, err = capture(m.cmd_status, NS(json=True, cached=True), cfgn)
pf = {x["name"]: x["ping_fail"] for x in json.loads(out)["accounts"]}
ok(pf["B"]["retry_at"] == m.ping_retry_at(m.load_state()["accounts"]["B"]), "card retry time and planner retry time come from the same rule")
m.update_state(lambda s: s["accounts"]["C"].update(last_ping=time.time() - 60, last_ping_ok=False, last_ping_kind="other"))
st = m.tick(cfgn)
ok(st["next_ping"]["name"] == "B" and abs(st["next_ping"]["at"] - m.ping_retry_at(st["accounts"]["B"])) < 1
   and "再试" in st["next_ping"]["why"], f"both waiting → 「接下来」 shows the earliest retry (B, 10 min): {st['next_ping']['why']}")
m.do_ping = lambda c, a, why: pings.append(a["name"]) or True

# ───── 5. 提醒分级 ─────
notes = []
m.notify = lambda msg, title="Cduo", kind="info", target=None: notes.append((title, kind, target))
def st_with(cur_util, cur_resets, other_util=0.0, other_resets=60 * MIN, hist=None):
    a = U(cur_util, cur_resets)
    if hist: a["hist"] = hist
    return {"accounts": {"A": a, "B": U(other_util, other_resets), "C": U(0, 4 * 3600)}, "desktop_current": "A"}
st = st_with(4, 4 * 3600)
rec = m.recommend(cfgn, st)
ok(rec["action"] == "switch" and rec["kind"] == "expiring", f"the 「use B before it expires」 suggestion still exists: {rec['reason']}")
notes.clear(); m.notify_policy(cfgn, st, rec, [])
ok(notes == [], "…but it no longer pops a notification by default (you only use 4%)")
cfge = dict(cfgn, notify_expiring=True)
m.notify_policy(cfge, st, rec, []); m.notify_policy(cfge, st, rec, [])
ok(notes == [("可以先用 B 的额度", "suggest_quiet", "B")], f"opted in → one quiet notification per window: {notes}")
notes.clear(); st = st_with(70, 4 * 3600); rec = m.recommend(cfgn, st); m.notify_policy(cfgn, st, rec, [])
ok(notes and notes[0][1] == "suggest_quiet", "current account already at 70% → the expiring hint is worth a quiet notification")
notes.clear(); st = st_with(96, 3600); rec = m.recommend(cfgn, st)
m.notify_policy(cfgn, st, rec, []); m.notify_policy(cfgn, st, rec, [])
ok(len(notes) == 1 and notes[0][1] == "suggest" and "快用完了" in notes[0][0], f"near the limit → one actionable notification per window: {notes}")
st2 = st_with(96, 5 * 3600); st2["notified"] = st.get("notified"); rec2 = m.recommend(cfgn, st2); m.notify_policy(cfgn, st2, rec2, [])
ok(len(notes) == 2, "next window near the limit again → notified again")
notes.clear()
t = time.time()
hist = [[t - 30 * MIN, 40.0], [t - 15 * MIN, 55.0], [t, 70.0]]   # 每分钟 1%：约 30 分钟后用完
st = st_with(70, 2 * 3600, other_util=10, other_resets=3 * 3600, hist=hist)
eta = m.eta_of(st["accounts"]["A"])
ok(eta and abs(eta - (t + 30 * MIN)) < 60, f"run-out predicted from the last hour: {dt.datetime.fromtimestamp(eta):%H:%M}")
rec = m.recommend(cfgn, st); m.notify_policy(cfgn, st, rec, []); m.notify_policy(cfgn, st, rec, [])
ok(len(notes) == 1 and "快用完了" in notes[0][0] and notes[0][2] in ("B", "C"),
   f"projected to run out before the refresh → one heads-up with the next account: {notes}")
ok(m.eta_of(dict(st["accounts"]["A"], resets_at=t + 20 * MIN)) is None, "refreshes before it would run out → no prediction")
ok(m.eta_of(dict(st["accounts"]["A"], hist=hist[-1:])) is None, "not enough history → no prediction")
notes.clear()
inter = [{"session": "local_x", "title": "t", "error_uuid": "e1"}]
st = st_with(100, 3600); rec = m.recommend(cfgn, st); m.notify_policy(cfgn, st, rec, inter)
ok(notes and notes[0][0] == "任务被额度打断了", "an interrupted task is still notified")

# 一天下来（每轮只用 4%）：以前 2 个号弹 3 次、3 个号弹 8 次，现在 0 次
def day(n):
    names = ["A", "B", "C"][:n]
    c = dict(cfgn, accounts=[x for x in cfg["accounts"] if x["name"] in names])
    day0 = dt.datetime(2026, 11, 18).timestamp(); gap = m.WINDOW / n
    starts = {x: [day0 + 3 * 3600 + i * gap + k * m.WINDOW for k in range(-1, 6)] for i, x in enumerate(names)}
    real_now, out, expiring = m.now, [], set()
    m.notify = lambda msg, title="Cduo", kind="info", target=None: out.append(title)
    st = {"accounts": {}, "desktop_current": "A"}
    tt = day0 + 6 * 3600
    while tt < day0 + 24 * 3600:
        m.now = lambda tt=tt: tt
        for x in names:
            r = next((s + m.WINDOW for s in starts[x] if s <= tt < s + m.WINDOW), None)
            st["accounts"][x] = {"ok": True, "no5h": False, "util": 4.0 if x == "A" else 1.0, "resets_at": r, "fetched": tt}
        rec = m.recommend(c, st)
        if rec.get("kind") == "expiring":
            expiring.add((rec["target"], st["accounts"][rec["target"]]["resets_at"]))
        m.notify_policy(c, st, rec, [])
        tt += 300
    m.now = real_now
    return len(out), len(expiring)
(n2, e2), (n3, e3) = day(2), day(3)
ok(e2 == 3 and e3 == 8, f"the old suggestion still comes up {e2}/{e3} times a day (it used to notify each time)")
ok(n2 == 0 and n3 == 0, "…and now pops 0 notifications on a light-use day, for 2 and for 3 accounts")
m.notify = lambda msg, title="Cduo", kind="info", target=None: notes.append((title, kind, target))

# ───── 6. 周额度 ─────
st = {"accounts": {"A": U(10, 3600, weekly_util=100.0), "B": U(20, 3 * 3600), "C": U(0, 4 * 3600)}, "desktop_current": "A"}
rec = m.recommend(cfgn, st)
ok(rec["action"] == "switch" and rec["urgent"] and "本周额度用完了" in rec["reason"], f"weekly quota used up → switch away: {rec['reason']}")
st = {"accounts": {"A": U(4, 4 * 3600), "B": U(0, 60 * MIN, weekly_util=85.0), "C": U(0, 4.5 * 3600)}, "desktop_current": "A"}
ok(m.recommend(cfgn, st)["action"] == "stay", "B's weekly quota is tight → don't suggest 「use B before it expires」")
st = {"accounts": {"A": U(100, 3600), "B": U(10, 60 * MIN, weekly_util=99.6), "C": U(10, 3 * 3600)}}
ok(m.pick_target(cfgn, st, exclude="A") == "C", "auto-switch skips an account whose weekly quota is used up")
exited, out, err = capture(m.cmd_status, NS(json=True, cached=True), cfgn)
ok("weekly_util" in json.loads(out)["accounts"][0] and "eta" in json.loads(out)["accounts"][0], "status JSON carries weekly_util and eta")

# ───── 7. 暂停预热 ─────
exited, out, err = capture(m.cmd_prewarm, NS(name="C", state="off"), cfg)
cfg = m.load_config()
ok(not exited and next(a for a in cfg["accounts"] if a["name"] == "C")["prewarm"] is False, "cduo prewarm C off")
cands, why, due = m.ping_candidates(cfg, {"accounts": {"A": U(40, 3600)}, "desktop_current": "A"})
ok([a["name"] for a in cands] == ["B"], "C no longer takes part in warm-ups")
ok(m.recommend(dict(cfg, auto_switch="notify"), {"accounts": {"A": U(99, 3600), "B": U(99, 3600), "C": U(5, 3 * 3600)},
                                                  "desktop_current": "A"})["target"] == "C",
   "…but it can still be switched to")
exited, out, err = capture(m.cmd_status, NS(json=True, cached=True), cfg)
ok(next(x for x in json.loads(out)["accounts"] if x["name"] == "C")["prewarm"] is False, "status JSON shows prewarm=false")
capture(m.cmd_prewarm, NS(name="C", state="on"), cfg); cfg = m.load_config()

# ───── 8. 移除并彻底清除 ─────
m.current_desktop_profile = lambda c, s: "A"
UD = "dddddddd-0000-0000-0000-000000000004"
cfg["accounts"].append({"name": "D", "label": "D", "account_uuid": UD, "org_uuid": ORG, "cli_dir": str(m.CLIROOT / "D"), "owned": True})
m.save_config(cfg)
(m.CLIROOT/"D").mkdir(); (m.CLIROOT/"D"/".credentials.json").write_text("{}")
(H/"desktop"/"D").mkdir(parents=True); (H/"desktop"/"D"/"oauth.json").write_text("{}")
(m.BACKUP/"20260101-000000-removed-D").mkdir(parents=True)
for name, uid in (("20260101-000001-to-A", UD), ("20260101-000002-to-B", UUID["A"])):
    (m.BACKUP/name).mkdir(); (m.BACKUP/name/"config.json").write_text(json.dumps({"lastKnownAccountUuid": uid}))
sec = []
real_run = m.subprocess.run
m.subprocess.run = lambda argv, **k: sec.append(argv) or real_run(["true"])
exited, out, err = capture(m.cmd_remove, NS(name="D", purge=True, force=False), cfg)
m.subprocess.run = real_run
names = [a["name"] for a in m.load_config()["accounts"]]
ok(not exited and "D" not in names, f"remove --purge drops D from the config: {out.strip()[:60]}")
ok(not (H/"desktop"/"D").exists() and not (m.BACKUP/"20260101-000000-removed-D").exists()
   and not (m.BACKUP/"20260101-000001-to-A").exists() and (m.BACKUP/"20260101-000002-to-B").exists(),
   "its snapshot and every backup holding its login are deleted; other backups stay")
ok(not (m.CLIROOT/"D").exists() and any(a[:2] == ["security", "delete-generic-password"] and m.kc_service(str(m.CLIROOT/"D")) in a
                                         for a in sec), "its CLI login (directory + keychain item) is deleted")
outside = T/"my-claude"; outside.mkdir(); (outside/".credentials.json").write_text("{}")
cfg = m.load_config()
cfg["accounts"].append({"name": "E", "label": "E", "account_uuid": UUID["A"], "org_uuid": ORG, "cli_dir": str(outside), "owned": True})
m.save_config(cfg)
exited, out, err = capture(m.cmd_remove, NS(name="E", purge=True, force=False), cfg)
ok(outside.exists() and (m.BACKUP/"20260101-000002-to-B").exists() and "没有动" in out and "保留" in out,
   "a CLI directory cduo didn't create is never deleted; backups shared with another account are kept")
exited, out, err = capture(m.cmd_remove, NS(name="A", purge=True, force=False), m.load_config())
ok(exited and any(a["name"] == "A" for a in m.load_config()["accounts"]), "the account the desktop app is using can't be removed")

# ───── 9. 安静的提醒：没有菜单栏时不退回成会弹横幅的系统通知 ─────
os.environ.pop("CDUO_NO_NOTIFY")
ran = []
m.subprocess.run = lambda argv, **k: ran.append(argv) or real_run(["true"])
importlib.reload  # noqa
real_notify = getattr(m, "_real_notify", None)
ld2 = importlib.machinery.SourceFileLoader("cduo2", SRC); m2 = importlib.util.module_from_spec(importlib.util.spec_from_loader("cduo2", ld2)); ld2.exec_module(m2)
m2.subprocess.run = lambda argv, **k: ran.append(argv) or real_run(["true"])
m2.notify("x", "quiet one", kind="suggest_quiet", target="B")
m2.notify("y", "normal one", kind="info")
m.subprocess.run = real_run; m2.subprocess.run = real_run
os.environ["CDUO_NO_NOTIFY"] = "1"
ok(len(ran) == 1 and "normal one" in " ".join(ran[0]), "without the menu bar, a quiet hint is skipped (no banner), a normal one still shows")

shutil.rmtree(T, ignore_errors=True)
print(f"\n{'全部通过' if not FAILS else f'{len(FAILS)} 项失败'}")
sys.exit(1 if FAILS else 0)
