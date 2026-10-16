#!/bin/zsh
# @author ixxxxoooo
# 构建并组装 OhMyAgent.app(默认 Debug;传入 release 构建发布版)。
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-debug}"
swift build -c "$CONFIG" --product OhMyAgent
swift build -c "$CONFIG" --product FakeAgent
swift build -c "$CONFIG" --product OhMyAgentBridge
BIN="$(swift build -c "$CONFIG" --show-bin-path)"
APP="build/OhMyAgent.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/OhMyAgent" "$APP/Contents/MacOS/OhMyAgent"
cp "$BIN/FakeAgent" "$APP/Contents/MacOS/FakeAgent"
cp "$BIN/OhMyAgentBridge" "$APP/Contents/MacOS/OhMyAgentBridge"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
for lproj in Resources/*.lproj(N); do cp -R "$lproj" "$APP/Contents/Resources/"; done
codesign --force --sign - --deep "$APP" >/dev/null 2>&1 || true
echo "已生成 $APP"
