#!/bin/zsh
# @author ixxxxoooo
# 构建并组装 OhMyAgent.app(默认 Debug;传入 release 构建发布版)。
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-debug}"
swift build -c "$CONFIG" --product OhMyAgent
swift build -c "$CONFIG" --product FakeAgent
BIN="$(swift build -c "$CONFIG" --show-bin-path)"
APP="build/OhMyAgent.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/OhMyAgent" "$APP/Contents/MacOS/OhMyAgent"
cp "$BIN/FakeAgent" "$APP/Contents/MacOS/FakeAgent"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
for lproj in Resources/*.lproj(N); do cp -R "$lproj" "$APP/Contents/Resources/"; done
# 内置 ACP 适配器:缺依赖时自动安装并裁剪,拷入 Resources/acp(应用据此免配置直接连接 Claude Code)
Scripts/stage-adapter.sh
mkdir -p "$APP/Contents/Resources/acp"
rsync -a --delete --exclude='.lock-hash' build/acp-stage/ "$APP/Contents/Resources/acp/"
codesign --force --sign - --deep "$APP" >/dev/null 2>&1 || true
echo "已生成 $APP"
