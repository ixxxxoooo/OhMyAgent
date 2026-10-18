#!/bin/zsh
# @author ixxxxoooo
# 性能回归(浸泡):以演示模式(脚本化 Agent + 隔离沙盒)启动应用,5 秒一次高频采样,
# 运行指定演示场景并保持一段时间,然后用 perf-report.py check 检查内存峰值/增长趋势/卡顿/积压。
# 用法: Scripts/perf-soak.sh [秒数,默认 90] [场景,默认 all(回归全集)]   需先 Scripts/bundle.sh。
# 阈值可用环境变量覆盖: SOAK_MAX_MB SOAK_MAX_DRIFT_MB SOAK_MAX_HITCH_MS
set -euo pipefail
source "${0:A:h}/lib-kill.sh"
cd "$(dirname "$0")/.."
SECONDS_TO_RUN="${1:-90}"
SCENARIO="${2:-all}"
APP="build/OhMyAgent.app"
[[ -d "$APP" ]] || { echo "没有 $APP,请先 Scripts/bundle.sh" >&2; exit 2; }
killDemoApp
sleep 1
open -g -n "$APP" --env OMA_DEMO=1 --env OMA_DEMO_RESET=1 --env OMA_PROJECT_ROOT="$PWD" \
  --env OMA_DEMO_SCENARIO="$SCENARIO" --env OMA_PERF_SAMPLE_SECONDS=5 --env OMA_AUTOALLOW=1
echo "浸泡 ${SECONDS_TO_RUN}s(场景 $SCENARIO,采样间隔 5s)…"
sleep "$SECONDS_TO_RUN"
PID="$(pgrep -x OhMyAgent | head -1 || true)"
[[ -n "$PID" ]] || { echo "应用已退出(崩溃?)" >&2; exit 1; }
python3 -I Scripts/perf-report.py mem --pid "$PID" | tail -8
set +e
python3 -I Scripts/perf-report.py check --pid "$PID" \
  --max-mb "${SOAK_MAX_MB:-600}" --max-drift-mb "${SOAK_MAX_DRIFT_MB:-80}" --max-hitch-ms "${SOAK_MAX_HITCH_MS:-1500}"
STATUS=$?
killDemoApp
exit $STATUS
