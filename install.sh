#!/bin/bash
# Cduo 安装 / 升级：
#   1. 命令行核心放到 ~/.cduo/app/cduo，链接成 ~/.local/bin/cduo
#   2. 菜单栏程序 Cduo.app：源码没变就保留现有的（辅助功能授权不受影响），变了才重建
#   3. 装桌面版「切号」skill
#   4. 已配置过账号的话，重装后台服务（每 5 分钟查额度 + 开机启动菜单栏）
set -euo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)"
CORE_DIR="$HOME/.cduo/app"
mkdir -p "$CORE_DIR" "$HOME/.local/bin" "$HOME/.cduo/logs"
chmod 700 "$HOME/.cduo"

DEST=/Applications
[ -w "$DEST" ] || { DEST="$HOME/Applications"; mkdir -p "$DEST"; }
APP="$DEST/Cduo.app"

# 菜单栏程序要不要重建：比较构建指纹（菜单栏源码 + 签名证书）
NEW_ID="$(bash "$SRC/build_app.sh" --id)"
OLD_ID="$(/usr/libexec/PlistBuddy -c 'Print :CduoBuildID' "$APP/Contents/Info.plist" 2>/dev/null || true)"
HAD_APP=0
[ -d "$APP" ] && HAD_APP=1
REBUILD=1
if [ -n "$OLD_ID" ] && [ "$NEW_ID" = "$OLD_ID" ] && codesign --verify --deep "$APP" >/dev/null 2>&1; then
  REBUILD=0
fi
if [ "$REBUILD" = 1 ]; then
  BUILD="$(mktemp -d)"
  trap 'rm -rf "$BUILD"' EXIT
  bash "$SRC/build_app.sh" "$BUILD"
fi

# 先停掉正在运行的旧菜单栏
UIDN=$(id -u)
launchctl bootout "gui/$UIDN/com.cduo.menubar" >/dev/null 2>&1 || true
pkill -f "Cduo.app/Contents/MacOS/Cduo" >/dev/null 2>&1 || true
pkill -f "$CORE_DIR/cduo-menubar" >/dev/null 2>&1 || true

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

if [ "$REBUILD" = 1 ]; then
  rm -rf "$APP"
  ditto "$BUILD/Cduo.app" "$APP"
  echo "✓ 已安装 ${APP}（$("$CORE_DIR/cduo" --version)）"
  if [ "$HAD_APP" = 1 ] && [ -z "${CDUO_SIGN_IDENTITY:-}" ] && ! grep -q . "$HOME/.cduo/sign-identity" 2>/dev/null; then
    echo "  菜单栏程序这次有更新。如果在用「自动续上」，请到 系统设置 → 隐私与安全性 → 辅助功能"
    echo "  里把 Cduo 关掉再打开一次。（以后都不想重新授权，见 README「升级后不用重新授权」）"
  fi
else
  echo "✓ 菜单栏程序没有变化，保留现有的 ${APP}（辅助功能授权不受影响）"
  echo "✓ 已更新命令行核心（$("$CORE_DIR/cduo" --version)）"
fi

mkdir -p "$HOME/.claude/skills/cduo"
cp "$SRC/skill/SKILL.md" "$HOME/.claude/skills/cduo/SKILL.md"

if /usr/bin/python3 - <<'EOF'
import json, os, sys
p = os.path.expanduser("~/.cduo/config.json")
sys.exit(0 if os.path.exists(p) and json.load(open(p)).get("accounts") else 1)
EOF
then
  "$CORE_DIR/cduo" agents install
  echo "✓ 菜单栏已重新启动（看屏幕右上角）"
else
  open "$APP"
  echo "下一步：点屏幕右上角的「Cduo」→「开始设置…」"
fi
