"""全自动换号 + 自动续上的场景测试（全部用假数据，不碰真实账号和桌面版）。

运行：python3 tests/test_resume.py
"""
import os, sys, json, time, pathlib, shutil, tempfile, importlib.util, importlib.machinery
SRC = sys.argv[1] if len(sys.argv) > 1 else str(pathlib.Path(__file__).resolve().parent.parent / "cduo")
T = pathlib.Path(tempfile.mkdtemp(prefix="cduo-test-"))
H = T/"home"; AS = T/"appsupport"; PR = T/"projects"
for d in (H, AS, PR): d.mkdir(parents=True)
os.environ.update(CDUO_HOME=str(H), CDUO_APP_SUPPORT=str(AS), CDUO_FAKE_DESKTOP="1", CDUO_DRY_PING="1", CDUO_NO_NOTIFY="1",
                  CDUO_RESUME_CHECK_WAIT="0")
ld = importlib.machinery.SourceFileLoader("cduo", SRC); spec = importlib.util.spec_from_loader("cduo", ld)
m = importlib.util.module_from_spec(spec); ld.exec_module(m)

ACC = {"A": "aaaaaaaa-0000-0000-0000-000000000001", "B": "bbbbbbbb-0000-0000-0000-000000000002"}
ORG = "cccccccc-0000-0000-0000-000000000003"
cfg = dict(m.DEFAULT_CONFIG); cfg["projects_dirs"] = [str(PR)]
cfg["accounts"] = [{"name": n, "account_uuid": u, "org_uuid": ORG, "cli_dir": str(H/"cli"/n)} for n, u in ACC.items()]
cfg["auto_switch"] = "idle"; cfg["prewarm_enabled"] = False
m.save_config(cfg)
for n in ACC:
    d = H/"desktop"/n; d.mkdir(parents=True); (d/"oauth.json").write_text("{}")
NOW = time.time()
iso = lambda t: time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(t)) + ".000Z"

def session(name, entries):
    cli = f"{abs(hash(name)) % 10**8:08d}-1111-2222-3333-444444444444"
    sid = f"local_{name}"
    for a in ACC.values():
        f = AS/"claude-code-sessions"/a/ORG; f.mkdir(parents=True, exist_ok=True)
        (f/f"{sid}.json").write_text(json.dumps({"sessionId": sid, "cliSessionId": cli, "title": name, "lastActivityAt": NOW*1000}))
    p = PR/"-proj"; p.mkdir(exist_ok=True)
    with open(p/f"{cli}.jsonl", "w") as fh:
        for e in entries: fh.write(json.dumps(e) + "\n")
    return sid, p/f"{cli}.jsonl"

U = lambda text, t: {"type": "user", "uuid": f"u{t}", "timestamp": iso(t), "message": {"role": "user", "content": text}}
A = lambda text, t: {"type": "assistant", "uuid": f"a{t}", "timestamp": iso(t), "message": {"role": "assistant", "content": [{"type": "text", "text": text}]}}
ERR = lambda text, t, err="rate_limit": {"type": "assistant", "uuid": f"e{t}", "timestamp": iso(t), "isApiErrorMessage": True, "error": err,
                                          "message": {"model": "<synthetic>", "role": "assistant", "content": [{"type": "text", "text": text}]}}
LIM = "You've hit your session limit · resets 2:30pm (Asia/Shanghai)"
S1, P1 = session("running-task", [U("做个大重构", NOW-600), A("好的，开始", NOW-590), ERR(LIM, NOW-60)])
S2, _ = session("user-replied", [U("hi", NOW-600), ERR(LIM, NOW-300), U("算了先不做", NOW-200)])
S3, _ = session("user-stopped", [U("hi", NOW-600), A("…", NOW-590), U("[Request interrupted by user]", NOW-100)])
S4, _ = session("spend-limit", [U("hi", NOW-600), ERR("You've hit your individual spend limit · ask your admin", NOW-100)])
S5, _ = session("idle-done", [U("hi", NOW-600), A("完成了", NOW-590)])
S6, _ = session("other-error", [U("hi", NOW-600), ERR("API Error: Connection lost mid-response", NOW-50, "server_error")])
S12, _ = session("limit-then-bgtask", [U("跑全部测试", NOW-600), ERR(LIM, NOW-120),
    dict(U("<task-notification>done</task-notification>", NOW-100), origin={"kind": "task-notification"})])
S7, _ = session("old-limit", [U("hi", NOW-9*3600), ERR(LIM, NOW-8*3600)])

usage = {}
def fake_fetch(cfg_, a):
    u = dict(usage[a["name"]]); u.setdefault("fetched", time.time()); u.setdefault("ok", True); u.setdefault("no5h", False); u.setdefault("error", None)
    return u
m.fetch_account_usage = fake_fetch
app = {"up": True}
m.desktop_pids = lambda: [4242] if app["up"] else []
m.wait_idle = lambda *a, **k: True
m.user_idle_seconds = lambda: 7200.0   # 假装你已经离开电脑两小时（不读真实的键盘鼠标空闲时间）
for fn in ("save_profile", "restore_profile", "pin_org_for", "backup_desktop"):
    setattr(m, fn, lambda *a, **k: None)
m.sync_sessions = lambda *a, **k: {}
m.desktop_org_hint = lambda: None
cur = {"name": "A"}
m.current_desktop_profile = lambda c, s: cur["name"]
_orig_switch = m.do_switch
switched = []
def spy_switch(c, target, **kw):
    switched.append((target, kw)); _orig_switch(c, target, **kw); cur["name"] = target
m.do_switch = spy_switch
notes = []
m.notify = lambda msg, title="Cduo", kind="info", target=None: notes.append((title, msg, kind, target))

def q(): return m.load_resume_q()["items"]
def reset_q():
    if m.RESUME_Q.exists(): m.RESUME_Q.unlink()
FAILS = []
def ok(c, msg):
    print(("PASS " if c else "FAIL ") + msg)
    if not c: FAILS.append(msg)

# 0. 检测
inter = m.find_interrupted(cfg, NOW - 6*3600)
ok(sorted(i["session"] for i in inter) == sorted([S1, S12]), f"only forced interruption detected: {[i['title'] for i in inter]}")

# 1. 全自动：A 用完、任务被打断、B 有余量 → 换到 B 并续上 S1
usage.update(A={"util": 100.0, "resets_at": NOW+3600}, B={"util": 10.0, "resets_at": NOW+7200})
st = m.load_state(); st["desktop_current"] = "A"; st["last_switch"] = {"at": NOW-3*3600}; m.save_state(st)
m.tick(cfg)
ok(switched and switched[-1][0] == "B", f"auto switched to B: {switched}")
items = q(); ok(sorted(i["session"] for i in items) == sorted([S1, S12]) and all(i["kind"] == "switch" for i in items), f"queued resume S1: {[(i['title'], i['kind']) for i in items]}")

# 2. 再 tick 一次：不应重复排队/重复切换
n_sw = len(switched); m.tick(cfg)
ok(len(switched) == n_sw and len(q()) == 2, "no repeat switch/queue")

# 3. resume next / check 流程
import io, contextlib
def run(argv):
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        ns = type("NS", (), {})(); ns.action, ns.session = argv[0], (argv[1] if len(argv) > 1 else None); ns.kind=None; ns.delay="0"
        m.cmd_resume(ns, cfg)
    return buf.getvalue().strip()
qq = m.load_resume_q(); qq["items"] = [i for i in qq["items"] if i["session"] == S1]; qq["items"][0]["not_before"] = 0; m.write_json(m.RESUME_Q, qq)
got = json.loads(run(["next"])); ok(got.get("session") == S1 and got.get("state") == "typing", "next hands out S1")
# 3a. 粘贴、回车之后，目标会话里没出现这句话：不再盲目重试（可能重复发、发错地方），改为通知你手动处理
r = json.loads(run(["check", S1]))
ok(r["ok"] is False and r["final"] is True and q()[0]["state"] == "manual", f"check w/o message → manual, no blind retry: {r}")
# 3b. 会话里出现了续上的话 → done
qq = m.load_resume_q(); qq["items"][0].update(state="pending", not_before=0); m.write_json(m.RESUME_Q, qq)
got = json.loads(run(["next"]))
with open(P1, "a") as fh: fh.write(json.dumps(U(m.RESUME_TEXT["switch"], time.time())) + "\n")
r = json.loads(run(["check", S1])); ok(r["ok"] is True and q()[0]["state"] == "done", f"check with message → done: {r}")
# 3c. 续上的话出现在了别的会话里 → 标记"发错了"，告诉你是哪个会话，也不重试
S13, P13 = session("target-13", [U("x", time.time()-50), A("好的", time.time()-40)])   # 只用来当目标会话，不算被打断
S14, P14 = session("wrong-14", [U("y", time.time()-50)])
m.queue_resume([{"session": S13, "cli": P13.stem, "title": "target-13", "error_uuid": "e13", "at": time.time()}], "switch", delay=0)
got = json.loads(run(["next"]))
# （+2 秒：和 3b 里 S1 那句正常续上的话错开，现实里 Cduo 一次只续一个、间隔远不止 2 秒）
with open(P14, "a") as fh: fh.write(json.dumps(U(m.RESUME_TEXT["switch"], time.time() + 2)) + "\n")
r = json.loads(run(["check", S13]))
ok(r["state"] == "misdelivered" and r["misdelivered_to"] == "wrong-14" and r["final"] is True, f"message landed elsewhere → reported: {r}")

# 4. 两个号都用完 → 等待，不切换
reset_q(); switched.clear(); notes.clear(); cur["name"] = "B"
S8, P8 = session("task-on-B", [U("继续写", time.time()-100), ERR(LIM, time.time()-30)])
usage.update(A={"util": 100.0, "resets_at": NOW+1800}, B={"util": 100.0, "resets_at": NOW+5000})
st = m.load_state(); st["desktop_current"] = "B"; st["last_switch"] = {"at": time.time()-200}; m.save_state(st)
st = m.tick(cfg)
ok(not switched and st.get("resume_wait", {}).get("until") == NOW+1800, f"both out → wait until A resets: {st.get('resume_wait')}")
ok(any(t == "两个号都用完了" for t, *_ in notes), f"wait notified: {notes}")
ok(not q(), "nothing queued while waiting")
ok(st.get("resume_wait", {}).get("count") == 1, "wait remembers 1 interrupted task")

# 5. A 刷新了 → 换到 A 并续上 S8
usage["A"] = {"util": 0.0, "resets_at": None}
m.tick(cfg)
ok(switched and switched[-1][0] == "A", f"after A resets → switch to A: {switched}")
ok([i["session"] for i in q()] == [S8], f"queued S8: {[i['title'] for i in q()]}")
ok("resume_wait" not in m.load_state(), "wait cleared")

# 6. 等待时本号刷新（不用换号）→ 原地续上 kind=reset
reset_q(); switched.clear(); cur["name"] = "A"
st = m.load_state(); st["desktop_current"] = "A"; st["last_switch"] = {"at": time.time()-100}; m.save_state(st)
S9, _ = session("task-on-A", [U("跑测试", time.time()-50), ERR(LIM, time.time()-20)])
usage.update(A={"util": 0.0, "resets_at": None}, B={"util": 100.0, "resets_at": NOW+5000})
m.tick(cfg)
ok(not switched and [(i["session"], i["kind"]) for i in q()] == [(S9, "reset")], f"own window reset → resume in place: {[(i['title'], i['kind']) for i in q()]}")

# 7. 提醒模式：被打断 → 只发通知（带切换按钮），不自动换
reset_q(); switched.clear(); notes.clear(); cfg["auto_switch"] = "notify"; m.save_config(cfg)
st = m.load_state(); st["desktop_current"] = "A"; st["last_switch"] = {"at": time.time()-60}; st["last_notified"] = None; m.save_state(st)
S10, _ = session("task-notify", [U("x", time.time()-40), ERR(LIM, time.time()-10)])
usage.update(A={"util": 100.0, "resets_at": NOW+1000}, B={"util": 5.0, "resets_at": NOW+9000})
m.tick(cfg)
ok(not switched and any(t == "任务被额度打断了" and k == "suggest" and tg == "B" for t, _, k, tg in notes), f"notify mode → actionable notification: {notes}")
# 7b. 用户点了通知上的切换 → do_switch 续上
m.do_switch(cfg, "B", after_turn=True)
ok([i["session"] for i in q()] == [S10], f"clicking switch resumes S10: {[i['title'] for i in q()]}")

# 8. 正常手动换号（没有被打断的任务）→ 不排队
reset_q(); cur["name"] = "B"
st = m.load_state(); st["last_switch"] = {"at": time.time()}; m.save_state(st)
m.do_switch(cfg, "A")
ok(not q(), "plain manual switch queues nothing")

# 9. 全自动：离开 >1h 且建议去用快作废的号 → 换号但不续上
reset_q(); switched.clear(); cfg["auto_switch"] = "idle"; m.save_config(cfg); cur["name"] = "A"
st = m.load_state(); st["desktop_current"] = "A"; st["last_switch"] = {"at": time.time()}; m.save_state(st)
usage.update(A={"util": 20.0, "resets_at": NOW+4*3600}, B={"util": 30.0, "resets_at": NOW+40*60})
m.last_transcript_write = lambda c: time.time() - 2*3600
m.tick(cfg)
ok(switched and switched[-1][0] == "B" and not q(), f"opportunistic switch after 1h idle, no resume: {switched}")
switched.clear(); cur["name"] = "A"; st = m.load_state(); st["desktop_current"] = "A"; m.save_state(st)
m.last_transcript_write = lambda c: time.time() - 60
m.tick(cfg)
ok(not switched, "no opportunistic switch while active")

# 10. 全自动：95% 不换（用完才换）
usage.update(A={"util": 96.0, "resets_at": NOW+3600}, B={"util": 10.0, "resets_at": NOW+9000})
m.tick(cfg)
ok(not switched, "auto mode does not switch at 96%")

# 11. 关掉自动续上 → 换号但不排队
reset_q(); switched.clear(); cfg["auto_resume"] = False; m.save_config(cfg)
st = m.load_state(); st["last_switch"] = {"at": time.time()-60}; m.save_state(st)
S11, _ = session("task-noresume", [U("x", time.time()-40), ERR(LIM, time.time()-10)])
usage.update(A={"util": 100.0, "resets_at": NOW+3600}, B={"util": 10.0, "resets_at": NOW+9000})
m.tick(cfg)
ok(switched and not q(), f"auto_resume off → switch only: {switched}")

# 12. 另一个号还有额度、但没在桌面版登录过 → need_login（不再误报"两个号都快用完了"）
cfg["auto_switch"] = "notify"; cfg["auto_resume"] = True; m.save_config(cfg)
shutil.rmtree(H/"desktop"/"B")
st = m.load_state(); st["desktop_current"] = "A"
st["accounts"] = {"A": dict(ok=True, util=99.0, resets_at=time.time()+3600, no5h=False), "B": dict(ok=True, util=21.0, resets_at=time.time()+9000, no5h=False)}
r = m.recommend(cfg, st)
ok(r["action"] == "need_login" and r["target"] == "B", f"no desktop login on B → need_login: {r}")
st["accounts"]["B"]["util"] = 100.0
r = m.recommend(cfg, st)
ok(r["action"] == "wait", f"both truly exhausted → wait: {r['action']}")

shutil.rmtree(T, ignore_errors=True)
print(f"\n{'全部通过' if not FAILS else f'{len(FAILS)} 项失败'}")
sys.exit(1 if FAILS else 0)
