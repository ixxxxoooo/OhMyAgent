#!/bin/zsh
# @author ixxxxoooo
# 演示模式:构建 → 以 OMA_DEMO=1 启动(使用脚本化 Agent 与隔离沙盒,不抢焦点)。
# 用法: Scripts/demo.sh [--reset] [--scenario <名>] [debug|release]
#   --reset            重建演示沙盒(项目、Git 仓库、工作台状态)
#   --scenario <名>    启动后自动运行指定演示场景(等价于 OMA_DEMO_SCENARIO)
# 环境变量: 所有 OMA_* 变量都会转发给应用,例如
#   OMA_DEMO_ROOT 改变沙盒目录(默认 ~/Library/Caches/OhMyAgent/Demo)
#   OMA_AUTOSEND="/demo-roles" OMA_ATTACH_IMAGE=图片路径 OMA_EXPAND_ALL=1 OMA_RIGHT_PANE=git ...
set -euo pipefail
source "${0:A:h}/lib-kill.sh"
cd "$(dirname "$0")/.."
RESET=""
SCENARIO=""
CONFIG="debug"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --reset) RESET="1" ;;
    --scenario) SCENARIO="${2:-}"; shift ;;
    debug|release) CONFIG="$1" ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
  shift
done
killDemoApp
sleep 0.3
Scripts/bundle.sh "$CONFIG"
export OMA_DEMO=1
export OMA_PROJECT_ROOT="$PWD"
[[ -n "$RESET" ]] && export OMA_DEMO_RESET=1
[[ -n "$SCENARIO" ]] && export OMA_DEMO_SCENARIO="$SCENARIO"
# 当前环境里所有 OMA_* 变量(调试钩子、OMA_AUTOSEND、OMA_ATTACH_IMAGE、OMA_DEMO_ROOT 等)都原样转发给应用
ARGS=()
for entry in ${(M)${(f)"$(env)"}:#OMA_*=*}; do ARGS+=(--env "$entry"); done
env -u TZ open -g -n build/OhMyAgent.app "${ARGS[@]}"
echo "已以演示模式启动 OhMyAgent(沙盒:${OMA_DEMO_ROOT:-~/Library/Caches/OhMyAgent/Demo})"
