#!/bin/bash
# 把 SwiftPM 可执行文件包成一个真正的 .app。
# 原因：WKWebView 的默认数据存储（也就是花瓣登录态）按 bundle identifier 找容器，
# 裸可执行文件没有 bundle id，登录能否跨启动保留会变得不可信。
set -euo pipefail

cd "$(dirname "$0")"

CONFIGURATION="${1:-debug}"
swift build -c "$CONFIGURATION"

BIN_PATH="$(swift build -c "$CONFIGURATION" --show-bin-path)"
APP_DIR="$PWD/build/WebCaptureSpike.app"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
cp "$BIN_PATH/WebCaptureSpike" "$APP_DIR/Contents/MacOS/WebCaptureSpike"

cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>WebCaptureSpike</string>
    <key>CFBundleIdentifier</key><string>com.pin.spike.WebCaptureSpike</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>WebCaptureSpike</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

printf 'APPL????' > "$APP_DIR/Contents/PkgInfo"

# 临时签名，避免每次启动都弹无法验证开发者的提示。
codesign --force --sign - "$APP_DIR" >/dev/null 2>&1 || true

echo "$APP_DIR"
