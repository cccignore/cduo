#!/bin/bash
# 构建 Cduo.app 到指定目录（默认 ./build）
set -euo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-$SRC/build}"
VER="$(/usr/bin/python3 "$SRC/cduo" --version)"
APP="$OUT/Cduo.app"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

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

install -m 755 "$SRC/cduo" "$APP/Contents/Resources/cduo"

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
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>两个 Claude 号：一键切换 + 额度错峰</string>
</dict></plist>
EOF

codesign --force --deep --sign - "$APP" >/dev/null 2>&1
echo "✓ 已构建 ${APP}（${VER}）"
