#!/bin/bash
# 构建 Cduo.app（菜单栏程序）到指定目录（默认 ./build）
#   bash build_app.sh [输出目录]
#   bash build_app.sh --id     只打印构建指纹，install.sh 用它判断菜单栏程序要不要重建
#
# 为什么要指纹：macOS 的「辅助功能」授权认的是 App 的签名。临时签名（ad-hoc）下，App 里任何
# 一个字节变了，授权就作废，得重新打开开关。所以只在菜单栏源码（或签名证书）变了时才重建；
# 只改了命令行核心 cduo 的升级不碰 Cduo.app，授权一直有效。
#
# 签名：设置了 CDUO_SIGN_IDENTITY，或者 ~/.cduo/sign-identity 里写了证书名，就用这个固定的
# 代码签名证书签名，菜单栏程序重建了授权也会保留。都没设置就用临时签名。
set -euo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)"

SIGN_ID="${CDUO_SIGN_IDENTITY:-}"
if [ -z "$SIGN_ID" ] && [ -f "$HOME/.cduo/sign-identity" ]; then
  SIGN_ID="$(head -n 1 "$HOME/.cduo/sign-identity" | tr -d '\r')"
fi
BUILD_ID="$( { cat "$SRC/menubar.swift" "$SRC/make_icon.swift" "$SRC/build_app.sh"; printf 'sign:%s' "${SIGN_ID:--}"; } \
  | shasum -a 256 | cut -c1-16)"
if [ "${1:-}" = "--id" ]; then
  echo "$BUILD_ID"
  exit 0
fi

OUT="${1:-$SRC/build}"
VER="$(/usr/bin/python3 "$SRC/cduo" --version)"
APP="$OUT/Cduo.app"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# 用和编译器配套的 SDK。环境里的 SDKROOT 可能指向另一套（常见：xcode-select 指向 Xcode，
# SDKROOT 却是命令行工具的 SDK），两边不配套时 SwiftUI 的 @State 宏插件找不到，编译直接失败。
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
export SDKROOT

echo "→ 编译 Cduo（约半分钟）…"
ARCH="$(uname -m)"
xcrun swiftc -O -target "$ARCH-apple-macos13.0" "$SRC/menubar.swift" -o "$APP/Contents/MacOS/Cduo"

echo "→ 生成图标…"
xcrun swiftc -O "$SRC/make_icon.swift" -o "$TMP/make_icon"
"$TMP/make_icon" "$TMP/icon.png"
ICONSET="$TMP/Cduo.iconset"; mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$TMP/icon.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$TMP/icon.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Cduo.icns"

# 命令行核心 cduo 不打进 App：它装在 ~/.cduo/app/cduo，菜单栏用的就是那一份。
# 打进来的话，每次只改 cduo 也会让 App 的签名变掉、辅助功能授权作废。

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.cduo.menubar</string>
  <key>CFBundleName</key><string>Cduo</string>
  <key>CFBundleDisplayName</key><string>Cduo</string>
  <key>CFBundleExecutable</key><string>Cduo</string>
  <key>CFBundleIconFile</key><string>Cduo</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VER</string>
  <key>CFBundleVersion</key><string>$VER</string>
  <key>CduoBuildID</key><string>$BUILD_ID</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>两个 Claude 号：一键切换 + 额度错峰</string>
</dict></plist>
EOF

if [ -n "$SIGN_ID" ]; then
  if ! out="$(codesign --force --deep --sign "$SIGN_ID" "$APP" 2>&1)"; then
    echo "✗ 用证书「${SIGN_ID}」签名失败：${out}" >&2
    echo "  钥匙串里有这个代码签名证书吗？不想用证书的话，删掉 ~/.cduo/sign-identity 再装。" >&2
    exit 1
  fi
  echo "→ 已用证书「${SIGN_ID}」签名"
elif ! out="$(codesign --force --deep --sign - "$APP" 2>&1)"; then
  echo "✗ 签名失败：$out" >&2
  exit 1
fi
echo "✓ 已构建 ${APP}（${VER}）"
