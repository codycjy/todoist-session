#!/usr/bin/env bash
# 构建并打包 Now.app（无需 Xcode 工程）。
# 用法：scripts/build-app.sh            （ad-hoc 签名）
#       SIGN_IDENTITY="My Cert" scripts/build-app.sh
#       INSTALL=1 scripts/build-app.sh   （另外装到 /Applications/Now.app）
set -euo pipefail

cd "$(dirname "$0")/.."
APP="build/Now.app"
EXE="SessionApp"

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$EXE" "$APP/Contents/MacOS/$EXE"
# 内置字体（JetBrains Mono，OFL）：由 Info.plist 的 ATSApplicationFontsPath 自动注册。
cp -R Sources/SessionApp/Resources/Fonts "$APP/Contents/Resources/Fonts"
# 图标由 scripts/make-icon.swift 生成。
cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>app.now.mac</string>
    <key>CFBundleName</key><string>Now</string>
    <key>CFBundleDisplayName</key><string>Now</string>
    <key>CFBundleExecutable</key><string>${EXE}</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>ATSApplicationFontsPath</key><string>Fonts</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>Now 需要控制浏览器（Safari、Chrome 等），以便在专注期间拦截黑名单网站并读取当前标签页的域名。</string>
    <key>NSUserNotificationsUsageDescription</key>
    <string>Now 需要发送通知，在专注或休息到点时提醒你。</string>
</dict>
</plist>
PLIST

# 有的终端或复制工具会给新文件打上隔离标记（com.apple.quarantine）。带这个标记、又没有经过公证的 App，
# 每次打开都会被 Gatekeeper 拦下来，弹出「无法验证」的提示。本机自己构建的包不需要这个标记。
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
codesign --force --sign "${SIGN_IDENTITY:--}" "$APP"

plutil -lint "$APP/Contents/Info.plist"
codesign --verify --verbose "$APP"
echo "OK: $APP"

if [[ "${INSTALL:-}" == "1" ]]; then
    DEST="/Applications/Now.app"
    osascript -e 'tell application id "app.now.mac" to quit' >/dev/null 2>&1 || true
    rm -rf "$DEST"
    ditto "$APP" "$DEST"
    xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
    echo "OK: $DEST"
fi
