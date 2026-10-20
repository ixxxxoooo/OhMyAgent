#!/bin/zsh
# @author ixxxxoooo
# 构建并组装应用。
# 用法: Scripts/bundle.sh [debug|release|dev]
#   debug   稳定身份的 Debug 构建 → build/OhMyAgent.app
#   release 稳定身份的 Release 构建 → build/OhMyAgent.app
#   dev     开发版(Debug 构建,Bundle ID 加 .dev,数据目录隔离)→ build/OhMyAgent Dev.app
# 签名:优先使用本地自签证书 "OhMyAgent Local Dev"(Scripts/make-signing-cert.sh 创建),
#       可用 OMA_SIGN_IDENTITY 覆盖;找不到证书时退回临时签名(每次重编译权限会重置)。
set -euo pipefail
cd "$(dirname "$0")/.."
MODE="${1:-debug}"
CONFIG="$MODE"
[[ "$MODE" == "dev" ]] && CONFIG="debug"
swift build -c "$CONFIG" --product OhMyAgent
swift build -c "$CONFIG" --product FakeAgent
BIN="$(swift build -c "$CONFIG" --show-bin-path)"
if [[ "$MODE" == "dev" ]]; then APP="build/OhMyAgent Dev.app"; else APP="build/OhMyAgent.app"; fi
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/OhMyAgent" "$APP/Contents/MacOS/OhMyAgent"
cp "$BIN/FakeAgent" "$APP/Contents/MacOS/FakeAgent"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [[ "$MODE" == "dev" ]]; then
  PLIST="$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.ixxxxoooo.OhMyAgent.dev" "$PLIST"
  /usr/libexec/PlistBuddy -c "Set :CFBundleName OhMyAgent Dev" "$PLIST"
  /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName OhMyAgent Dev" "$PLIST"
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
for lproj in Resources/*.lproj(N); do cp -R "$lproj" "$APP/Contents/Resources/"; done
IDENTITY="${OMA_SIGN_IDENTITY:-OhMyAgent Local Dev}"
if ! security find-identity -v -p codesigning | grep -q "\"$IDENTITY\""; then
  echo "警告:未找到签名证书 \"$IDENTITY\",退回临时签名(运行 Scripts/make-signing-cert.sh 创建)"
  IDENTITY="-"
fi
codesign --force --sign "$IDENTITY" --deep "$APP" >/dev/null 2>&1 || true
echo "已生成 $APP(签名:$IDENTITY)"
