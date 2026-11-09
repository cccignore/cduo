#!/bin/bash
# Cduo 安装 / 升级：
#   1. 构建 Cduo.app 并放进「应用程序」
#   2. 命令行核心放到 ~/.cduo/app/cduo，链接成 ~/.local/bin/cduo
#   3. 装桌面版「切号」skill
#   4. 已配置过账号的话，重装后台服务（每 5 分钟查额度 + 开机启动菜单栏）
set -euo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)"
CORE_DIR="$HOME/.cduo/app"
mkdir -p "$CORE_DIR" "$HOME/.local/bin" "$HOME/.cduo/logs"
chmod 700 "$HOME/.cduo"

DEST=/Applications
[ -w "$DEST" ] || { DEST="$HOME/Applications"; mkdir -p "$DEST"; }

BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT
bash "$SRC/build_app.sh" "$BUILD"

# 先停掉正在运行的旧菜单栏
UIDN=$(id -u)
launchctl bootout "gui/$UIDN/com.cduo.menubar" >/dev/null 2>&1 || true
pkill -f "Cduo.app/Contents/MacOS/Cduo" >/dev/null 2>&1 || true
pkill -f "$CORE_DIR/cduo-menubar" >/dev/null 2>&1 || true

rm -rf "$DEST/Cduo.app"
ditto "$BUILD/Cduo.app" "$DEST/Cduo.app"
install -m 755 "$SRC/cduo" "$CORE_DIR/cduo"
ln -sf "$CORE_DIR/cduo" "$HOME/.local/bin/cduo"
# 让「终端」里能直接敲 cduo：~/.local/bin 不在 PATH 里就加到 ~/.zprofile
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) if ! grep -qs '.local/bin' "$HOME/.zprofile"; then
       printf '\n# cduo\nexport PATH="$HOME/.local/bin:$PATH"\n' >> "$HOME/.zprofile"
       echo "✓ 已把 ~/.local/bin 加入 PATH（新开的终端窗口生效）"
     fi ;;
esac
rm -f "$CORE_DIR/cduo-menubar" "$CORE_DIR/menubar.swift"   # v0.1 的旧菜单栏

mkdir -p "$HOME/.claude/skills/cduo"
cp "$SRC/skill/SKILL.md" "$HOME/.claude/skills/cduo/SKILL.md"

echo "✓ 已安装 $DEST/Cduo.app（$("$CORE_DIR/cduo" --version)）"

if /usr/bin/python3 - <<'EOF'
import json, os, sys
p = os.path.expanduser("~/.cduo/config.json")
sys.exit(0 if os.path.exists(p) and json.load(open(p)).get("accounts") else 1)
EOF
then
  "$CORE_DIR/cduo" agents install
  echo "✓ 菜单栏已重新启动（看屏幕右上角）"
else
  open "$DEST/Cduo.app"
  echo "下一步：点屏幕右上角的「Cduo」→「开始设置…」"
fi
