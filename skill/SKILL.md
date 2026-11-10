---
name: cduo
description: 切换 Claude 桌面版账号、查看各个账号的 5 小时额度、换号出问题时恢复登录。Use when the user says "切号", "换号", "切到另一个号", "切到 <账号名>", "额度怎么样", "看下额度", "还剩多少额度", "switch account", "换号后要重新登录", "恢复换号前的登录".
---

# cduo：双账号切换 / 额度

工具在 `~/.local/bin/cduo`（数据在 `~/.cduo/`）。

## 看额度
运行 `~/.local/bin/cduo status`，把输出原样转述给用户（哪个号在用、各用了多少、几点重置、有没有切换建议、下一次预热时间）。

## 切号
1. 用户说了目标账号名就用它；没说就不带参数，cduo 会按规则（先用快到期的号）自己选。
2. 运行 `~/.local/bin/cduo switch [名字]`。它会在后台等这一轮回复结束，然后自动重启 Claude 并换成目标账号。
3. 告诉用户：Claude 十几秒后会自动重启；重启后点开原来的会话就能接着聊，上下文都在；换号后第一条消息会稍微多耗一点额度（缓存要重建）。
4. 运行完 switch 后立刻结束本轮回复，不要再调用其他工具（否则会推迟重启）。

如果 switch 报「没有换号：……」，说明 Claude 的文件结构和 cduo 认识的不一样，cduo 什么都没改。把原因转述给用户，建议运行 `~/.local/bin/cduo doctor` 看详情。

## 换号出了问题
用户说换号后 Claude 要求重新登录、或者想回到换号前的登录：
1. 运行 `~/.local/bin/cduo restore` 列出备份（每次换号前都会自动备份），告诉用户有哪些。
2. 用户确认后运行 `~/.local/bin/cduo restore latest`（或用户选的那个备份名）。它会等这一轮回复结束后重启 Claude 并恢复。
3. 运行完 restore 后立刻结束本轮回复，不要再调用其他工具。

## 登录某个号却变成了另一个号
几个号属于同一个组织、走同一个 SSO 时，登录页由系统默认浏览器打开。浏览器里还登录着另一个号时，SSO 会直接放行，就登录成了那个号。`~/Library/Logs/Claude/main.log` 里会看到 `Starting ASWebAuth for: /sso/authorize`，几秒内就完成，没有输入密码的步骤。
- 额度那一栏显示「未登录」：是这个号的 CLI 凭据没了。运行 `~/.local/bin/cduo login <名字>`（从 Claude 里运行会自动打开「终端」）。它会在无痕窗口里打开授权页并预填邮箱，不受浏览器里已登录账号的影响；登成别的号会自动撤销。不用改默认浏览器。
- 桌面版登录（`cduo login-desktop <名字>`）走系统的 ASWebAuth，只能用默认浏览器的普通窗口，没法强制无痕。换号时 cduo 会把桌面版最新 token 存回快照，所以只有长期不用或登录被撤销时才需要重做。需要重做时，让用户临时把默认浏览器换成没登录过这些号的浏览器（一般是 Safari），登录保存后再换回去；这个流程会提醒并可打开设置页，登错号时可以直接重来。改默认浏览器只能由用户自己操作。

## 某个号一直「满额 · 未开始计时」
预热由后台任务 `com.cduo.tick` 每 5 分钟执行；菜单栏刷新只读额度，不会预热。运行 `~/.local/bin/cduo agents status`，显示 tick「未安装」就是后台任务没加载（例如手动暂停后没恢复、换机迁移后还没重新登录过）。`cduo status` 会自动补加载（10 分钟查一次，日志里记 `tick agent was not loaded; bootstrap -> ok`），也可以手动运行 `~/.local/bin/cduo agents install --no-menubar`。菜单栏是手动打开的时候，不带 `--no-menubar` 去装可能会再开一个菜单栏。

## 不要在这里做的事
`cduo setup`、`cduo desktop-login` 需要在「终端」App 里交互运行，在这里只提示用户去终端执行。
