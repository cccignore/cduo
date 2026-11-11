"""三个及以上账号的场景测试：错峰间隔、推荐、自动换号挑哪个号、提示文字、加号 / 移除号。
全部用假数据，不碰真实账号、钥匙串和桌面版。

运行：python3 tests/test_multi.py
"""
import os, sys, json, time, pathlib, shutil, tempfile, io, contextlib
import importlib.util, importlib.machinery

SRC = sys.argv[1] if len(sys.argv) > 1 else str(pathlib.Path(__file__).resolve().parent.parent / "cduo")
T = pathlib.Path(tempfile.mkdtemp(prefix="cduo-multi-"))
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
cfg["prewarm_enabled"] = False
cfg["accounts"] = [{"name": n, "label": n, "account_uuid": u, "org_uuid": ORG, "cli_dir": str(H/"cli"/n), "owned": True}
                   for n, u in UUID.items()]
m.save_config(cfg)
for n in UUID:
    (H/"cli"/n).mkdir(parents=True)
    (H/"desktop"/n).mkdir(parents=True); (H/"desktop"/n/"oauth.json").write_text("{}")

def U(util, resets_in=None):
    return {"ok": True, "no5h": False, "util": util, "fetched": time.time(), "error": None,
            "resets_at": time.time() + resets_in if resets_in is not None else None}

# ───── 1. 错峰：3 个号均分 5 小时，每隔 1h40m 开始一个 ─────
acct, why, due = m.plan_pings(cfg, {"accounts": {}, "desktop_current": "B"})
ok(acct and acct["name"] == "B", f"nothing running → start the account in use first: {why}")
acct, why, due = m.plan_pings(cfg, {"accounts": {"A": U(10, 199 * MIN)}, "desktop_current": "A"})
ok(acct and acct["name"] == "B", f"A started 101 min ago (> 1h40m) → start the next one now: {why}")
acct, why, due = m.plan_pings(cfg, {"accounts": {"A": U(10, 250 * MIN)}, "desktop_current": "A"})
ok(acct is None and abs(due - (time.time() + 50 * MIN)) < 5 and "1h40m" in why,
   f"A started 50 min ago → next one starts in 50 min: {why}")
acct, why, due = m.plan_pings(cfg, {"accounts": {"A": U(10, 250 * MIN), "B": U(10, 150 * MIN), "C": U(5, 50 * MIN)},
                                    "desktop_current": "A"})
ok(acct is None and why.startswith("3 个号都在计时"), f"all three running → nothing to do: {why}")

# ───── 2. 推荐：在还有额度的号里挑最早刷新的 ─────
cn = dict(cfg, auto_switch="notify", switch_threshold=95)
st = {"accounts": {"A": U(96, 200 * MIN), "B": U(40, 180 * MIN), "C": U(70, 60 * MIN)}, "desktop_current": "A"}
r = m.recommend(cn, st)
ok(r["action"] == "switch" and r["target"] == "C" and r["urgent"], f"A used up → C (resets soonest among usable): {r}")
st = {"accounts": {"A": U(99, 200 * MIN), "B": U(97, 180 * MIN), "C": U(96, 60 * MIN)}, "desktop_current": "A"}
r = m.recommend(cn, st)
ok(r["action"] == "wait" and r["reason"].startswith("3 个号都快用完了"), f"all three over the threshold → wait: {r['reason']}")

# ───── 3. 自动换号的目标：<90% 的号里最早刷新的 ─────
st = {"accounts": {"A": U(100, 200 * MIN), "B": U(20, 240 * MIN), "C": U(85, 30 * MIN)}}
ok(m.pick_target(cfg, st, exclude="A") == "C", "pick_target → C (still under 90%, resets in 30 min)")
st["accounts"]["C"] = U(92, 30 * MIN)
ok(m.pick_target(cfg, st, exclude="A") == "B", "C over 90% → B")

# ───── 4. 全自动 tick：A 用完 → 换到 C，不是"另一个号"里随便一个 ─────
usage = {}
m.fetch_account_usage = lambda c, a: dict(usage[a["name"]])
m.desktop_pids = lambda: [4242]
m.wait_idle = lambda *a, **k: True
m.user_idle_seconds = lambda: 7200.0
m.current_desktop_profile = lambda c, s: "A"
m.desktop_org_hint = lambda: None
m.sync_sessions = lambda *a, **k: {}
switched = []
real_do_switch = m.do_switch
m.do_switch = lambda c, target, **kw: switched.append(target)
notes = []
m.notify = lambda msg, title="Cduo", kind="info", target=None: notes.append(title)
ci = dict(cfg, auto_switch="idle")
usage.update(A=U(100, 200 * MIN), B=U(10, 240 * MIN), C=U(30, 60 * MIN))
m.save_state({"accounts": {}, "desktop_current": "A", "last_switch": {"at": time.time() - 3 * 3600}})
m.tick(ci, allow_ping=False)
ok(switched == ["C"], f"full-auto: A used up → switch to C: {switched}")
switched.clear()
usage.update(A=U(100, 200 * MIN), B=U(100, 240 * MIN), C=U(100, 60 * MIN))
st = m.tick(ci, allow_ping=False)
ok(not switched and "3 个号都用完了" in notes, f"all three used up → wait, notification says 3 个号: {notes[-1:]}")
ok(abs((st.get("resume_wait") or {}).get("until", 0) - (time.time() + 60 * MIN)) < 5, "waits for C, which resets first")

# ───── 5. 不带名字的 cduo switch 按同一个规则挑 ─────
picked = []
m.do_switch = lambda c, target, **kw: picked.append(target)
real_tick = m.tick
m.tick = lambda c, **kw: {"accounts": {"A": U(50, 200 * MIN), "B": U(20, 240 * MIN), "C": U(30, 40 * MIN)},
                          "recommend": {"action": "stay", "target": "A"}, "desktop_current": "A"}
capture(m.cmd_switch, NS(name=None, after_turn=False, no_relaunch=True, force=False, detached=False), cfg)
ok(picked == ["C"], f"`cduo switch` with no name → C (resets soonest), not just the first other one: {picked}")
m.tick = real_tick
m.do_switch = real_do_switch

# ───── 6. cduo setup --add：只加一个号，不再问作息时间 ─────
answers = ["bad name!", "A", "D", "第四个", ""]       # 不合规的名字、重名都会重问
asked = []
def fake_ask(prompt, default=""):
    asked.append(prompt)
    return answers.pop(0) if answers else default
m.ask = fake_ask
m.read_creds = lambda d: (None, None)                 # 新号还没登录（也别去碰钥匙串）
def fake_login(c, a):                                 # 假装在浏览器里授权了，而且登的是和 B 同一个号
    a.update(account_uuid=UUID["B"], org_uuid=ORG, email="b-again@example.com"); m.save_config(c); return True
m.cli_login = fake_login
logins = []
m.desktop_login_flow = lambda c, a, s: logins.append(a["name"])
installed = []
m.install_agents = lambda *a, **k: installed.append(True)
m.cmd_status = lambda *a, **k: None
m.find_claude_bin = lambda: "/usr/bin/true"           # 没装 claude 的机器（比如 CI）上，向导会先问 claude 路径
(T/"agents").mkdir(); (T/"agents"/"com.cduo.tick.plist").write_text("x")
m.agent_path = lambda label: T/"agents"/f"{label}.plist"   # 后台调度已经装过
exited, out, err = capture(m.cmd_setup, NS(add=True), cfg)
ok(not exited and [a["name"] for a in cfg["accounts"]] == ["A", "B", "C", "D"], f"setup --add adds exactly one account: {err[-80:]}")
ok(not any("几点" in p for p in asked), "setup --add doesn't ask for work hours again")
ok(out.count("名字只能用") == 1 and out.count("已经有一个叫 A") == 1, "bad and duplicate names are asked again instead of quitting")
ok("同一个账号、同一个组织" in out, "adding the same login twice is flagged (quota is shared)")
ok(logins == ["D"] and not installed and "后台调度已经在跑" in out, "only the new account logs in to the desktop; agents left alone")

# ───── 7. cduo remove ─────
m.current_desktop_profile = lambda c, s: "A"
exited, out, err = capture(m.cmd_remove, NS(name="A", force=False), cfg)
ok(exited and any(a["name"] == "A" for a in m.load_config()["accounts"]), "can't remove the account the desktop app is using")
(H/"desktop"/"D").mkdir(parents=True, exist_ok=True); (H/"desktop"/"D"/"oauth.json").write_text("{}")
m.update_state(lambda s: s["accounts"].__setitem__("D", U(5, 100 * MIN)))
cfg = m.load_config()
exited, out, err = capture(m.cmd_remove, NS(name="D", force=False), cfg)
names = [a["name"] for a in m.load_config()["accounts"]]
ok(not exited and names == ["A", "B", "C"] and "D" not in m.load_state()["accounts"], f"remove D → gone from config and state: {names}")
ok(not (H/"desktop"/"D").exists() and list(m.BACKUP.glob("*-removed-D")), "D's desktop snapshot moved into the backups")
ok((H/"cli"/"D").exists(), "D's CLI login is kept for re-adding later")

# ───── 8. 文字 ─────
ok(m.accounts_text(2) == "两个号" and m.accounts_text(5) == "5 个号", "wording: 两个号 / 5 个号")

shutil.rmtree(T, ignore_errors=True)
print(f"\n{'全部通过' if not FAILS else f'{len(FAILS)} 项失败'}")
sys.exit(1 if FAILS else 0)
