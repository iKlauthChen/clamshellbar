#!/bin/bash
# 构建 ClamshellBar.app 与 CLI 工具 clamshell
# 用法：./build.sh [--install]
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="ClamshellBar"
BUNDLE_ID="local.clamshell.bar"
OUT="build"
APP="$OUT/$APP_NAME.app"

rm -rf "$OUT"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> 编译菜单栏应用"
swiftc -O Sources/menubar.swift -o "$APP/Contents/MacOS/$APP_NAME" \
    -framework AppKit -framework IOKit

echo "==> 编译命令行工具"
swiftc -O Sources/cli.swift -o "$OUT/clamshell"

cp Resources/AppIcon.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

echo "==> ad-hoc 签名"
codesign --force --deep --sign - "$APP"

echo "==> 打包 zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/$APP_NAME.zip"

if [[ "${1:-}" == "--install" ]]; then
    echo "==> 安装到 /Applications"
    rm -rf "/Applications/$APP_NAME.app"
    cp -R "$APP" /Applications/
    "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister" \
        -f "/Applications/$APP_NAME.app" || true
    open "/Applications/$APP_NAME.app"
fi

echo "完成：$APP"
