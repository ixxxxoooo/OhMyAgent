#!/bin/zsh
# @author ygw
# 性能门槛验证:多次冷启动测量「进程启动→首帧」耗时,并采样空载内存(footprint)。
# 用法: Scripts/perf.sh [次数,默认 5]   需先 Scripts/bundle.sh release。
set -euo pipefail
cd "$(dirname "$0")/.."
RUNS="${1:-5}"
APP="build/OhMyAgent.app"
OUT="$(mktemp /tmp/oma-perf.XXXXXX)"
results=()
for i in $(seq 1 "$RUNS"); do
  pkill -x OhMyAgent 2>/dev/null || true
  pkill -x FakeAgent 2>/dev/null || true
  sleep 1
  rm -f "$OUT"
  open -g -n "$APP" --env OMA_AGENT=fake --env OMA_PERF_OUT="$OUT"
  for _ in $(seq 1 100); do [[ -s "$OUT" ]] && break; sleep 0.1; done
  ms="$(cat "$OUT" 2>/dev/null || echo -1)"
  results+=("$ms")
  echo "第 $i 次: 首帧 ${ms}ms"
done
sleep 4
PID="$(pgrep -x OhMyAgent | head -1)"
echo "---- 空载内存(启动 4 秒后)----"
footprint -p "$PID" 2>/dev/null | rg -i "phys_footprint|Footprint:|OhMyAgent \[" | head -5 || true
ps -o rss=,pcpu= -p "$PID" | awk '{printf "RSS %.1f MB, CPU %s%%\n", $1/1024, $2}'
echo "首帧耗时序列(ms): ${results[*]}"
rm -f "$OUT"
