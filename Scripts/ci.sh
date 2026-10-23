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
# IDE 性能基线检查脚本自检
python3 Scripts/ide-bench-check.py --self-test
swift build --scratch-path /tmp/oma-ci -Xswiftc -warnings-as-errors
Scripts/test.sh
plutil -lint Resources/Info.plist Resources/*.lproj/*.strings
# 可选:性能浸泡回归(需先打包;默认不跑,避免拖慢 CI 与抢占本机应用)。OMA_CI_PERF=1 Scripts/ci.sh
if [[ "${OMA_CI_PERF:-0}" == "1" ]]; then
  Scripts/bundle.sh release
  Scripts/perf-soak.sh "${OMA_CI_PERF_SECONDS:-90}"
  # IDE 基线回归(需已有 Scripts/perf-baseline.json)
  [[ -f Scripts/perf-baseline.json ]] && Scripts/demo-bench.sh --only ide --no-build --check-baseline
  # 原生编辑器(editor.*)门禁:120Hz 预算 + 与基线比对(release 构建)
  Scripts/editor-bench.sh --no-build --check-baseline
fi
# 兜底清理:Swift 工具链会在系统临时目录遗留空的 TemporaryDirectory.*,测试也可能遗留目录
Scripts/clean-test-tmp.sh >/dev/null 2>&1 || true
echo "CI 通过"
