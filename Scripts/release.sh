#!/bin/zsh
# @author ixxxxoooo
# 发布流水线:release 构建 → 打包瘦身后的 ACP 适配器 → Developer ID 签名(Hardened Runtime)
#            → 公证并装订 → 生成 zip/dmg 与 appcast 条目。
#
# 用法:
#   DEVELOPER_ID="Developer ID Application: 名字 (TEAMID)" \
#   NOTARY_PROFILE="oma-notary" \          # 预先执行: xcrun notarytool store-credentials oma-notary …
#   OMA_VERSION=0.2.0 OMA_BUILD=12 \       # 可选:覆盖 Info.plist 的版本号
#   OMA_DOWNLOAD_BASE="https://example.com/oma" \   # 可选:appcast 中的下载前缀
#   Scripts/release.sh
#
# 未设置 DEVELOPER_ID 时使用 ad-hoc 签名并跳过公证(仅用于本机演练,产物无法分发)。
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/OhMyAgent.app"
IDENTITY="${DEVELOPER_ID:--}"
ENTITLEMENTS="Resources/OhMyAgent.entitlements"
PLIST="Resources/Info.plist"

# 1. 构建与组装
Scripts/bundle.sh release

# 2. 版本号(只改产物里的 Info.plist,不动源文件)
if [[ -n "${OMA_VERSION:-}" ]]; then /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $OMA_VERSION" "$APP/Contents/Info.plist"; fi
if [[ -n "${OMA_BUILD:-}" ]]; then /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $OMA_BUILD" "$APP/Contents/Info.plist"; fi
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"

# 3. Claude ACP 适配器是编进应用本体的原生 Swift 实现(ClaudeAgentKit),无需额外资源;运行只依赖本机 claude

# 4. 签名:先签内嵌可执行文件,最后签 app 本体(不使用 --deep)
SIGN_ARGS=(--force --sign "$IDENTITY" --options runtime --entitlements "$ENTITLEMENTS")
if [[ "$IDENTITY" != "-" ]]; then SIGN_ARGS+=(--timestamp); fi
for helper in FakeAgent; do
  codesign "${SIGN_ARGS[@]}" "$APP/Contents/MacOS/$helper"
done
codesign "${SIGN_ARGS[@]}" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

# 5. 压缩包(公证与分发都用)
mkdir -p dist
ZIP="dist/OhMyAgent-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

# 6. 公证 + 装订
if [[ "$IDENTITY" != "-" && -n "${NOTARY_PROFILE:-}" ]]; then
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  spctl --assess --type execute --verbose=2 "$APP"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
else
  echo "跳过公证(需要 DEVELOPER_ID 与 NOTARY_PROFILE)"
fi

# 7. DMG:暂存目录放 app 与「Applications」快捷方式,用户可直接拖动安装;
#    构建前清掉 dist 里旧的 dmg(只保留本次产物),暂存目录与挂载点用 trap 兜底清理。
DMG="dist/OhMyAgent-$VERSION.dmg"
find dist -maxdepth 1 -name "*.dmg" -delete 2>/dev/null || true
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/oma-dmg.XXXXXX")"
VERIFY_MOUNT=""
cleanup_dmg() {
  if [[ -n "$VERIFY_MOUNT" ]]; then hdiutil detach -quiet "$VERIFY_MOUNT" 2>/dev/null || true; fi
  rm -rf "$STAGE"
}
trap cleanup_dmg EXIT
ditto "$APP" "$STAGE/OhMyAgent.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "OhMyAgent $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
# 挂载校验:必须同时包含 app 与 Applications 快捷方式
VERIFY_MOUNT="$(mktemp -d "${TMPDIR:-/tmp}/oma-dmg-verify.XXXXXX")"
hdiutil attach -quiet -nobrowse -readonly -mountpoint "$VERIFY_MOUNT" "$DMG"
[[ -d "$VERIFY_MOUNT/OhMyAgent.app" && -L "$VERIFY_MOUNT/Applications" ]] || { echo "错误:dmg 内容不完整(缺少 app 或 Applications 快捷方式)"; exit 1; }
hdiutil detach -quiet "$VERIFY_MOUNT"
rmdir "$VERIFY_MOUNT" 2>/dev/null || true
VERIFY_MOUNT=""
if [[ "$IDENTITY" != "-" ]]; then
  codesign --force --sign "$IDENTITY" --timestamp "$DMG"
  if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
  fi
fi

# 8. appcast 条目(合并到发布源 JSON 的 stable 或 preview 键下)
SHA="$(shasum -a 256 "$DMG" | awk '{print $1}')"
BASE="${OMA_DOWNLOAD_BASE:-https://example.com/oma}"
CHANNEL="${OMA_CHANNEL:-stable}"
cat > "dist/appcast-$CHANNEL.json" <<JSON
{
  "$CHANNEL": {
    "version": "$VERSION",
    "build": $BUILD,
    "url": "$BASE/OhMyAgent-$VERSION.dmg",
    "sha256": "$SHA",
    "minimumSystemVersion": "27.0",
    "notes": "${OMA_NOTES:-}"
  }
}
JSON
echo "完成:$DMG  (sha256 $SHA)"
echo "appcast 片段:dist/appcast-$CHANNEL.json(合并后上传到更新源)"
