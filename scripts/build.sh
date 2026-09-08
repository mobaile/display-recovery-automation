#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "${0:A:h}/.." && pwd)"
cd "$ROOT_DIR"

echo "构建 Release 目标"
xcrun swift build -c release
BIN_DIR="$(xcrun swift build -c release --show-bin-path)"

DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/ScreenPilot.app"
OLD_APP_DIR="$DIST_DIR/DisplayRecoveryAutomation.app"
mkdir -p "$DIST_DIR"
rm -rf "$APP_DIR" "$OLD_APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp "$BIN_DIR/DisplayRecoveryApp" "$APP_DIR/Contents/MacOS/ScreenPilot"
cp "$ROOT_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"

# 非沙盒应用需要访问 USB HID；临时 ad-hoc 签名便于本机直接启动。
codesign --force --deep --sign - "$APP_DIR"
cp "$BIN_DIR/display-recovery-cli" "$DIST_DIR/display-recovery-cli"

echo "已生成：$APP_DIR"
echo "已生成：$DIST_DIR/display-recovery-cli"
