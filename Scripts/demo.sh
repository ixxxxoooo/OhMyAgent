#!/bin/zsh
# @author ygw
# 演示模式:构建 → 以 OMA_DEMO=1 启动(使用脚本化 Agent 与隔离沙盒,不抢焦点)。
# 用法: Scripts/demo.sh [--reset] [--scenario <名>] [debug|release]
#   --reset            重建演示沙盒(项目、Git 仓库、工作台状态)
#   --scenario <名>    启动后自动运行指定演示场景(等价于 OMA_DEMO_SCENARIO)
# 环境变量: OMA_DEMO_ROOT 可改变沙盒目录(默认 ~/Library/Caches/OhMyAgent/Demo)
set -euo pipefail
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
pkill -x OhMyAgent 2>/dev/null || true
pkill -x FakeAgent 2>/dev/null || true
pkill -x OhMyAgentBridge 2>/dev/null || true
sleep 0.3
Scripts/bundle.sh "$CONFIG"
ARGS=(--env OMA_DEMO=1 --env OMA_PROJECT_ROOT="$PWD")
[[ -n "$RESET" ]] && ARGS+=(--env OMA_DEMO_RESET=1)
[[ -n "$SCENARIO" ]] && ARGS+=(--env OMA_DEMO_SCENARIO="$SCENARIO")
[[ -n "${OMA_DEMO_ROOT:-}" ]] && ARGS+=(--env OMA_DEMO_ROOT="$OMA_DEMO_ROOT")
open -g -n build/OhMyAgent.app "${ARGS[@]}"
echo "已以演示模式启动 OhMyAgent(沙盒:${OMA_DEMO_ROOT:-~/Library/Caches/OhMyAgent/Demo})"
