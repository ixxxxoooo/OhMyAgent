#!/bin/zsh
# @author ygw
# 本地 CI 门槛:零警告构建(-warnings-as-errors)+ 全部单元/协议/性能基线测试。
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --scratch-path /tmp/oma-ci -Xswiftc -warnings-as-errors
swift test
plutil -lint Resources/Info.plist Resources/en.lproj/Localizable.strings
echo "CI 通过"
