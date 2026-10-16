#!/bin/zsh
# @author ixxxxoooo
# 本地 CI 门槛:零警告构建(-warnings-as-errors)+ 全部单元/协议/性能基线测试。
set -euo pipefail
cd "$(dirname "$0")/.."
# 本地化门槛:中文字面量必须有英文翻译,且中文资源与英文键同步
python3 Scripts/l10n-scan.py --check
python3 Scripts/sync-zh-strings.py --check
# UI 规范门槛:字号/颜色/按钮/图标/复制图标必须走设计系统
python3 Scripts/ui-lint.py --check
swift build --scratch-path /tmp/oma-ci -Xswiftc -warnings-as-errors
swift test
plutil -lint Resources/Info.plist Resources/*.lproj/*.strings
echo "CI 通过"
