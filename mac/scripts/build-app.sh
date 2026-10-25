#!/usr/bin/env bash
# 构建并打包 Session.app（无需 Xcode 工程）。
# 用法：scripts/build-app.sh            （ad-hoc 签名）
#       SIGN_IDENTITY="My Cert" scripts/build-app.sh
set -euo pipefail

cd "$(dirname "$0")/.."
APP="build/Session.app"
EXE="SessionApp"

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$EXE" "$APP/Contents/MacOS/$EXE"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>app.session.mac</string>
    <key>CFBundleName</key><string>Session</string>
    <key>CFBundleDisplayName</key><string>Session</string>
    <key>CFBundleExecutable</key><string>${EXE}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>Session 需要控制浏览器（Safari、Chrome 等），以便在专注期间拦截黑名单网站并读取当前标签页的域名。</string>
    <key>NSUserNotificationsUsageDescription</key>
    <string>Session 需要发送通知，以便在一个专注时段结束时提醒你休息。</string>
</dict>
</plist>
PLIST

codesign --force --sign "${SIGN_IDENTITY:--}" "$APP"

plutil -lint "$APP/Contents/Info.plist"
codesign --verify --verbose "$APP"
echo "OK: $APP"
