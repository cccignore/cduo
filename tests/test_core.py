"""核心逻辑测试：调度规则、凭据续期、state 并发写、通知队列、换号回滚与恢复、兼容性检查、
会话活动检测、续上核对、日志轮转、备份清理。全部用假数据，不碰真实账号、钥匙串和桌面版。

运行：python3 tests/test_core.py
"""
import os, sys, json, time, pathlib, shutil, tempfile, sqlite3, threading, io, contextlib
import datetime as dt, importlib.util, importlib.machinery

SRC = sys.argv[1] if len(sys.argv) > 1 else str(pathlib.Path(__file__).resolve().parent.parent / "cduo")
T = pathlib.Path(tempfile.mkdtemp(prefix="cduo-core-"))
H = T/"home"; AS = T/"appsupport"; PR = T/"projects"
for d in (H, AS, PR): d.mkdir(parents=True)
# 在 Claude 桌面版里跑测试时，别让 cduo 以为自己在桌面版会话里（那样会另起后台进程）
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

NOW = time.time()
UA, UB = "aaaaaaaa-0000-0000-0000-000000000001", "bbbbbbbb-0000-0000-0000-000000000002"
ORG = "cccccccc-0000-0000-0000-000000000003"
cfg = json.loads(json.dumps(m.DEFAULT_CONFIG))
cfg["projects_dirs"] = [str(PR)]
cfg["prewarm_enabled"] = False
cfg["accounts"] = [{"name": n, "label": n, "account_uuid": u, "org_uuid": ORG, "cli_dir": str(H/"cli"/n), "owned": True}
                   for n, u in (("A", UA), ("B", UB))]
m.save_config(cfg)
for a in cfg["accounts"]:
    pathlib.Path(a["cli_dir"]).mkdir(parents=True)
ACC_A = cfg["accounts"][0]

def creds(name, left_sec, token):
    """CLI 凭据写成文件（有文件就不会去碰钥匙串）。"""
    (H/"cli"/name/".credentials.json").write_text(json.dumps({"claudeAiOauth": {
        "accessToken": token, "refreshToken": "r-" + name, "expiresAt": int((time.time() + left_sec) * 1000),
        "scopes": ["user:inference"]}}))
creds("A", 3600, "tokA"); creds("B", 3600, "tokB")

def cookies_db(path, cols=("host_key", "name", "value", "encrypted_value", "path"), marker="x"):
    with contextlib.suppress(FileNotFoundError): path.unlink()
    con = sqlite3.connect(str(path))
    con.execute(f"create table cookies ({', '.join(c + ' TEXT' for c in cols)})")
    con.execute("create table meta (k TEXT)")
    con.execute("insert into meta values (?)", (marker,))
    con.commit(); con.close()

def cookie_marker(path):
    con = sqlite3.connect(str(path)); r = con.execute("select k from meta").fetchone()[0]; con.close(); return r

def desktop(uuid, token, marker):
    """假装桌面版当前登录的是 uuid。"""
    (AS/"config.json").write_text(json.dumps({"lastKnownAccountUuid": uuid, "oauth:tokenCacheV2": token, "keep": 1}))
    cookies_db(AS/"Cookies", marker=marker)

def profile(name, uuid, token, marker):
    d = H/"desktop"/name; d.mkdir(parents=True, exist_ok=True)
    (d/"oauth.json").write_text(json.dumps({"lastKnownAccountUuid": uuid, "oauth:tokenCacheV2": token}))
    cookies_db(d/"Cookies", marker=marker)

def at(hh, mm=0):
    return dt.datetime.now().replace(hour=hh, minute=mm, second=0, microsecond=0).timestamp()

def iso(t):
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(t)) + ".000Z"

def capture(fn, *a, **k):
    """跑一个可能 die() 的函数，返回 (是否退出, stdout, stderr)。"""
    out, err, exited = io.StringIO(), io.StringIO(), False
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        try:
            fn(*a, **k)
        except SystemExit:
            exited = True
    return exited, out.getvalue(), err.getvalue()

class NS:
    def __init__(self, **kw): self.__dict__.update(kw)

USAGE = lambda util, resets: {"ok": True, "no5h": False, "util": util, "resets_at": resets, "fetched": time.time()}
real_idle = m.user_idle_seconds

# ───── 1. 调度规则 ─────
c2 = dict(cfg, active_hours={"start": "22:00", "end": "02:00"})
ok(m.in_active_hours(c2, at(23)) and m.in_active_hours(c2, at(1)) and not m.in_active_hours(c2, at(3)),
   "active hours wrap past midnight")

acct, why, due = m.plan_pings(cfg, {"accounts": {}, "desktop_current": "B"})
ok(acct and acct["name"] == "B" and abs(due - time.time()) < 5, f"nothing running → start the account in use: {why}")
acct, why, due = m.plan_pings(cfg, {"accounts": {"A": USAGE(10, time.time() + 2.5 * 3600)}, "desktop_current": "A"})
ok(acct and acct["name"] == "B", f"A started 2.5h ago → start B now: {why}")
acct, why, due = m.plan_pings(cfg, {"accounts": {"A": USAGE(10, time.time() + 4 * 3600)}, "desktop_current": "A"})
ok(acct is None and abs(due - (time.time() + 1.5 * 3600)) < 5, f"A started 1h ago → B starts in 1.5h: {why}")

profile("A", UA, "encA", "pA"); profile("B", UB, "encB", "pB")
cn = dict(cfg, auto_switch="notify", switch_threshold=95)
st = {"accounts": {"A": USAGE(50, time.time() + 4 * 3600), "B": USAGE(20, time.time() + 3600)}, "desktop_current": "A"}
r = m.recommend(cn, st)
ok(r["action"] == "switch" and r["target"] == "B" and not r["urgent"], f"B resets soon with 80% left → use it first: {r}")
st["accounts"]["A"] = USAGE(96, time.time() + 4 * 3600)
r = m.recommend(cn, st)
ok(r["action"] == "switch" and r["urgent"], f"A over threshold → urgent switch: {r}")
st = {"accounts": {"A": USAGE(100, time.time() + 600), "B": USAGE(100, time.time() + 3600)}, "desktop_current": "A"}
ok(m.recommend(dict(cfg, auto_switch="idle"), st)["action"] == "wait", "both used up → wait")

# ───── 2. 凭据续期：刷新失败不误报"过期" ─────
calls = []
def http_fail(c, url, data=None, headers=None, timeout=20):
    calls.append(url); raise OSError("network down")
m.http_json = http_fail
creds("A", 10 * 60, "tokA")       # 还剩 10 分钟：会去刷新
ok(m.ensure_fresh_token(cfg, ACC_A) == "tokA" and calls, "refresh fails but old token still valid → keep using it")
lock = H/"cli"/"A"/".oauth_refresh.lock"; lock.mkdir(); calls.clear()
ok(m.ensure_fresh_token(cfg, ACC_A) == "tokA" and not calls, "another process is refreshing → use the old token")
lock.rmdir()
creds("A", -60, "tokA")           # 已经过期
ok(m.ensure_fresh_token(cfg, ACC_A) is None, "expired and refresh fails → no token")
u = m.fetch_account_usage(cfg, ACC_A)
ok("刷新失败" in (u.get("error") or ""), f"usage error says the refresh failed: {u.get('error')}")
def http_ok(c, url, data=None, headers=None, timeout=20):
    if url == m.TOKEN_URL:
        return {"access_token": "tokA2", "refresh_token": "r2", "expires_in": 3600}
    return {"five_hour": {"utilization": 42, "resets_at": "2099-01-01T00:00:00Z"}}
m.http_json = http_ok
ok(m.ensure_fresh_token(cfg, ACC_A) == "tokA2", "refresh succeeds → new token")
saved = json.loads((H/"cli"/"A"/".credentials.json").read_text())["claudeAiOauth"]
ok(saved["accessToken"] == "tokA2" and saved["refreshToken"] == "r2", "refreshed token is saved")
u = m.fetch_account_usage(cfg, ACC_A)
ok(u["ok"] and u["util"] == 42.0, "usage fetched with the new token")

# ───── 3. 请求头里的版本号跟着本机 claude 走 ─────
fake = T/"bin"/"claude"; fake.parent.mkdir(); fake.write_text("#!/bin/sh\necho '2.3.4 (Claude Code)'\n"); fake.chmod(0o755)
cache = m.CDUO/".claude-version"
with contextlib.suppress(FileNotFoundError): cache.unlink()
ok(m.claude_version(dict(cfg, claude_bin=str(fake))) == "2.3.4", "version read from local claude")
ok(m.claude_version(dict(cfg, claude_bin=None)) == "2.3.4", "version cached for a day")
cache.unlink()
ok(m.claude_version(dict(cfg, claude_bin=None)) == m.UA_FALLBACK_VERSION and not cache.exists(),
   "claude missing → fallback version, and nothing cached")
ok(m.claude_version(dict(cfg, claude_bin=str(fake))) == "2.3.4", "claude installed later → real version picked up right away")
bad = T/"bin"/"claude-broken"; bad.write_text("#!/bin/sh\necho oops\n"); bad.chmod(0o755)
cache.unlink()
ok(m.claude_version(dict(cfg, claude_bin=str(bad))) == m.UA_FALLBACK_VERSION and cache.read_text() == "",
   "claude gives no version → fallback, retry after an hour instead of every request")

# ───── 4. 通知队列：一条一个文件，并发写不丢 ─────
os.environ.pop("CDUO_NO_NOTIFY")
(m.CDUO/".menubar_alive").touch()
th = [threading.Thread(target=m.notify, args=(f"msg{i}", "T")) for i in range(20)]
for t in th: t.start()
for t in th: t.join()
files = sorted(m.NOTIFY_DIR.glob("*.json"))
msgs = sorted(json.loads(f.read_text())["msg"] for f in files)
ok(msgs == sorted(f"msg{i}" for i in range(20)), f"20 concurrent notifications → 20 complete files ({len(files)})")
ok(not [p for p in m.NOTIFY_DIR.iterdir() if p.name.startswith(".")], "no temp files left behind")
os.environ["CDUO_NO_NOTIFY"] = "1"
(m.CDUO/".menubar_alive").unlink(); shutil.rmtree(m.NOTIFY_DIR)

# ───── 5. tick 联网期间别人写的字段不会被冲掉 ─────
desktop(UA, "encA", "dA")
real_fetch = m.fetch_account_usage
def racing_fetch(c, a):
    if a["name"] == "A":   # 这段时间里，换号进程写了 last_switch，续上排队写了 resume_handled
        m.update_state(lambda s: s.__setitem__("last_switch", {"at": 12345.0, "to": "B"}))
        m.update_state(lambda s: s.setdefault("resume_handled", {}).__setitem__("e-race", 1.0))
    return {"fetched": time.time(), "ok": True, "no5h": False, "util": 10.0, "resets_at": time.time() + 3600, "error": None}
m.fetch_account_usage = racing_fetch
m.save_state({"accounts": {}})
st = m.tick(cfg, allow_ping=False)
ok(st.get("last_switch", {}).get("at") == 12345.0 and "e-race" in (st.get("resume_handled") or {}),
   "tick doesn't clobber fields written while it was fetching")
ok(st.get("desktop_current") == "A" and st["accounts"]["A"]["util"] == 10.0, "tick still writes its own fields")
m.fetch_account_usage = real_fetch

# ───── 6. 换号写到一半失败 → 自动回滚 ─────
desktop(UA, "encA", "dA")
before_conf = (AS/"config.json").read_text()
real_restore = m.restore_profile
def broken_restore(name):
    real_restore(name)              # config.json、Cookies 已经换成 B 的了……
    raise OSError("磁盘满了")         # ……然后出错
m.restore_profile = broken_restore
exited, out, err = capture(m.do_switch, cfg, "B")
m.restore_profile = real_restore
ok(exited and "已恢复到切换前的登录" in err, f"half-done switch → error mentions the rollback: {err.strip()[-50:]}")
ok((AS/"config.json").read_text() == before_conf and cookie_marker(AS/"Cookies") == "dA",
   "half-done switch rolled back to A's login")
st = m.load_state()
ok(st.get("desktop_current") != "B" and not st.get("switching"), "state is not marked as switched")

# ───── 7. 会话列表同步失败不影响换号 ─────
real_sync = m.sync_sessions
def broken_sync(*a, **k): raise RuntimeError("sync boom")
m.sync_sessions = broken_sync
exited, out, err = capture(m.do_switch, cfg, "B")
m.sync_sessions = real_sync
conf = json.loads((AS/"config.json").read_text())
ok(not exited and conf["lastKnownAccountUuid"] == UB and conf.get("keep") == 1 and cookie_marker(AS/"Cookies") == "pB",
   "session-list sync failure doesn't cancel a completed switch")
st = m.load_state()
ok(st.get("desktop_current") == "B" and (st.get("last_switch") or {}).get("to") == "B", "state records the switch")

# ───── 8. cduo restore ─────
names = [p.name for p in m.list_desktop_backups()]
ok(len(names) >= 2 and all("to-B" in n for n in names), f"a backup is taken before every switch: {names}")
exited, out, err = capture(m.cmd_restore, NS(name=None, detached=False), cfg)
ok("to-B" in out and " A" in out, "restore lists backups with the account they hold")
exited, out, err = capture(m.cmd_restore, NS(name="latest", detached=False), cfg)
conf = json.loads((AS/"config.json").read_text())
ok(not exited and conf["lastKnownAccountUuid"] == UA and cookie_marker(AS/"Cookies") == "dA", "restore latest → back to A's login")
ok(m.load_state().get("desktop_current") == "A", "state follows the restored login")
ok(json.loads((H/"desktop"/"B"/"oauth.json").read_text())["oauth:tokenCacheV2"] == "encB",
   "B's latest login is saved before restoring")
exited, out, err = capture(m.cmd_restore, NS(name="../../etc", detached=False), cfg)
ok(exited, "restore rejects names outside the backup folder")

# ───── 9. 兼容性检查：不认识的结构一律不动 ─────
(AS/"config.json").write_text(json.dumps({"lastKnownAccountUuid": UA}))   # 有账号，却没有登录字段
n_bk = len(m.list_desktop_backups())
exited, out, err = capture(m.do_switch, cfg, "B")
ok(exited and "登录信息" in err and json.loads((AS/"config.json").read_text()) == {"lastKnownAccountUuid": UA}
   and len(m.list_desktop_backups()) == n_bk, "unrecognized config.json → refuse to switch, touch nothing")
desktop(UA, "encA", "dA"); cookies_db(AS/"Cookies", cols=("host", "value"))
ok(any("表结构" in p for p in m.desktop_compat_problems()), "changed Cookies schema is detected")
desktop(UA, "encA", "dA")
ok(m.desktop_compat_problems() == [], "normal desktop files pass the check")
(H/"desktop"/"B"/"oauth.json").write_text(json.dumps({"lastKnownAccountUuid": UB}))
exited, out, err = capture(m.do_switch, cfg, "B")
ok(exited and json.loads((AS/"config.json").read_text())["lastKnownAccountUuid"] == UA,
   "snapshot without login info → refused and rolled back")
profile("B", UB, "encB", "pB")

# ───── 10. 快照整份替换，被打断也能恢复 ─────
m.save_profile("A")
ok(not list((H/"desktop").glob(".A.*")), "saving a snapshot leaves no temp folders")
os.replace(H/"desktop"/"A", H/"desktop"/".A.old")        # 模拟：换快照时正好被打断
ok(m.has_profile("A"), "an interrupted snapshot swap is recovered")

# ───── 11. 会话活动：只看桌面版自己的会话 ─────
def session(name, cli, age):
    for acc in (UA, UB):
        f = AS/"claude-code-sessions"/acc/ORG; f.mkdir(parents=True, exist_ok=True)
        (f/f"local_{name}.json").write_text(json.dumps({"sessionId": f"local_{name}", "cliSessionId": cli, "title": name,
                                                        "lastActivityAt": (time.time() - age) * 1000}))
    p = PR/"-proj"/f"{cli}.jsonl"; p.parent.mkdir(exist_ok=True)
    p.write_text(json.dumps({"type": "user", "timestamp": "2020-01-01T00:00:00Z", "message": {"content": "hi"}}) + "\n")
    os.utime(p, (time.time() - age, time.time() - age))
    return p
CX, CY, CZ = ("11111111-1111-1111-1111-111111111111", "22222222-2222-2222-2222-222222222222",
              "33333333-3333-3333-3333-333333333333")
PX = session("X", CX, 3600); PY = session("Y", CY, 7200)
pz = PR/"-cli-proj"/f"{CZ}.jsonl"; pz.parent.mkdir(); pz.write_text("{}\n")   # 终端里的 claude，桌面版没有它的记录
lw = m.last_transcript_write(cfg)
ok(abs(lw - (time.time() - 3600)) < 5, f"activity = newest desktop session; terminal claude ignored ({time.time() - lw:.0f}s ago)")
sub = PX.parent/CX/"subagents"; sub.mkdir(parents=True); (sub/"agent-1.jsonl").write_text("{}\n")
ok(time.time() - m.last_transcript_write(cfg) < 5, "subagent activity counts")
shutil.rmtree(PX.parent/CX)
real_root = m.SESSIONS_ROOT; m.SESSIONS_ROOT = T/"nowhere"
ok(time.time() - m.last_transcript_write(cfg) < 5, "no desktop session list → fall back to all transcripts")
m.SESSIONS_ROOT = real_root

m.user_idle_seconds = lambda: 1.0      # 你一直在动键盘鼠标
ok(m.wait_idle(cfg, quiet=1, max_wait=3, user_idle=30) is False and m.wait_idle.last_reason == "user",
   "auto switch waits while you're using the computer")
m.user_idle_seconds = lambda: 120.0
ok(m.wait_idle(cfg, quiet=1, max_wait=10, user_idle=30) is True, "proceeds once you're away and sessions are quiet")
ok(m.user_away(600) is False and m.user_away(60) is True, "user_away compares idle seconds")
m.user_idle_seconds = real_idle
v = real_idle()
ok(v is None or v >= 0, f"reads the real keyboard/mouse idle time ({v})")

# ───── 12. 续上核对：不盲目重试，发错地方要说出来 ─────
m.desktop_pids = lambda: [4242]
def resume(action, session=None):
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        m.cmd_resume(NS(action=action, session=session, kind=None, delay="0"), cfg)
    return json.loads(out.getvalue().strip().splitlines()[-1])
m.queue_resume([{"session": "local_X", "cli": CX, "title": "X", "error_uuid": "eX", "at": time.time()}], "switch", delay=0)
ok(resume("next").get("session") == "local_X", "next hands out X")
with open(PY, "a") as fh:   # 续上的话被发进了 Y
    fh.write(json.dumps({"type": "user", "timestamp": iso(time.time()), "message": {"content": m.RESUME_TEXT["switch"]}}) + "\n")
r = resume("check", "local_X")
ok(r["ok"] is False and r["final"] is True and r["state"] == "misdelivered" and r["misdelivered_to"] == "Y",
   f"message landed in another session → reported, no retry: {r}")
PY.write_text("{}\n")
m.queue_resume([{"session": "local_X", "cli": CX, "title": "X", "error_uuid": "eX2", "at": time.time()}], "switch", delay=0)
resume("next")
r = resume("check", "local_X")
ok(r["state"] == "manual" and r["final"] is True, f"nothing showed up → manual fallback, no blind retry: {r}")
ok(not [i for i in m.load_resume_q()["items"] if i.get("state") in ("pending", "typing")], "nothing left to retry")

m.write_json(m.RESUME_Q, {"items": []})
th = [threading.Thread(target=m.queue_resume, args=([{"session": f"local_T{i}", "cli": None, "title": f"T{i}",
                                                       "error_uuid": f"t{i}", "at": time.time()}], "switch"))
      for i in range(10)]
for t in th: t.start()
for t in th: t.join()
ok(len(m.load_resume_q()["items"]) == 10, "concurrent queueing loses nothing")
ok(all(f"t{i}" in m.load_state().get("resume_handled", {}) for i in range(10)), "concurrent state updates lose nothing")

# ───── 13. 换号后变成未登录 → 提醒一次怎么恢复 ─────
notes = []
real_notify = m.notify
m.notify = lambda msg, title="Cduo", kind="info", target=None: notes.append(title)
(AS/"config.json").write_text(json.dumps({"lastKnownAccountUuid": UB}))
st = {"last_switch": {"at": time.time() - 120, "to": "B"}}
m.check_after_switch(st, True)
ok(notes == ["换号可能没成功"] and st.get("post_switch_warned"), "logged out right after a switch → one warning")
m.check_after_switch(st, True)
ok(len(notes) == 1, "warned only once per switch")
m.notify = real_notify
desktop(UA, "encA", "dA")

# ───── 14. 日志轮转、备份清理 ─────
m.LOG_MAX = 1000
(m.LOGDIR/"cduo.log").write_text("x" * 2000)
m.log("hello")
ok((m.LOGDIR/"cduo.log.1").exists() and (m.LOGDIR/"cduo.log").stat().st_size < 100, "log rotated past the size limit")
m.LOG_MAX = 2 * 1024 * 1024
for i in range(20):
    (m.BACKUP/f"20200101-0000{i:02d}-to-A").mkdir(parents=True)
    (m.BACKUP/f"20200101-0000{i:02d}-sessions").mkdir(parents=True)
m._prune_backups()
logins = [p for p in m.BACKUP.iterdir() if not p.name.endswith("-sessions")]
sessions = [p for p in m.BACKUP.iterdir() if p.name.endswith("-sessions")]
ok(len(logins) == m.BACKUP_KEEP and len(sessions) == m.BACKUP_KEEP, f"each kind keeps {m.BACKUP_KEEP} backups")
ok(any(p.name.endswith("before-restore") for p in logins), "the newest real backups survive pruning")

# ───── 15. 菜单栏读的 status --json 还能正常输出 ─────
exited, out, err = capture(m.cmd_status, NS(json=True, cached=True), cfg)
ok(not exited and json.loads(out)["accounts"][0]["name"] == "A", "status --json still works")

shutil.rmtree(T, ignore_errors=True)
print(f"\n{'全部通过' if not FAILS else f'{len(FAILS)} 项失败'}")
sys.exit(1 if FAILS else 0)
