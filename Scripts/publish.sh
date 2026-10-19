#!/bin/zsh
# @author ixxxxoooo
# 发布正式版:release 构建打包 → 打 tag → 推送 → 创建 GitHub Release(附 dmg/zip 与 appcast.json)。
# 应用内「检查更新」默认读取 releases/latest/download/appcast.json,发布后即自动生效。
#
# 用法: Scripts/publish.sh [版本号]      # 缺省取 Resources/Info.plist 的版本号,如 1.0.0
#   OMA_NOTES="更新说明"                 # 可选,缺省取上一个 tag 以来的提交标题
#   DEVELOPER_ID / NOTARY_PROFILE        # 可选,透传给 Scripts/release.sh(缺省为 ad-hoc 签名、不公证)
set -euo pipefail
cd "$(dirname "$0")/.."

REPO="ixxxxoooo/OhMyAgent"
VERSION="${1:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)}"
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] || { echo "错误:版本号格式不正确:$VERSION"; exit 1; }
TAG="v$VERSION"
[[ -z "$(git status --porcelain)" ]] || { echo "错误:工作区有未提交改动,请先提交"; exit 1; }
git rev-parse "$TAG" >/dev/null 2>&1 && { echo "错误:tag $TAG 已存在"; exit 1; }

# 构建号取提交数,保证单调递增
export OMA_VERSION="$VERSION"
export OMA_BUILD="$(git rev-list --count HEAD)"
export OMA_DOWNLOAD_BASE="https://github.com/$REPO/releases/download/$TAG"
export OMA_CHANNEL=stable
PREV="$(git describe --tags --abbrev=0 2>/dev/null || true)"
if [[ -z "${OMA_NOTES:-}" ]]; then
  RANGE="${PREV:+$PREV..}HEAD"
  OMA_NOTES="$(git log "$RANGE" --pretty='%s' | head -20 | sed 's/"/\\"/g' | paste -sd ';' -)"
  export OMA_NOTES
fi

Scripts/release.sh

# appcast 文件名固定为 appcast.json,取通道键内容即完整发布源
cp "dist/appcast-stable.json" dist/appcast.json
python3 -c 'import json;json.load(open("dist/appcast.json"))["stable"]["url"]'

git tag -a "$TAG" -m "OhMyAgent $VERSION"
git push origin "$TAG"
gh release create "$TAG" --repo "$REPO" --title "OhMyAgent $VERSION" \
  --notes "$(printf '%s\n' "$OMA_NOTES" | tr ';' '\n' | sed 's/^/- /')" --latest \
  "dist/OhMyAgent-$VERSION.dmg" "dist/OhMyAgent-$VERSION.zip" dist/appcast.json
echo "已发布:https://github.com/$REPO/releases/tag/$TAG"
