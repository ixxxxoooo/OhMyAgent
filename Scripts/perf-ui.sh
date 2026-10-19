#!/bin/zsh
# @author ixxxxoooo
# 交互性能基准(演示模式:脚本化 Agent + 隔离沙盒,不碰开发版与真实会话):
#   interact  冷打开 N 个会话 → 在标签间热切换 → 左右侧栏各开关 M 次,汇总「侧栏切换/标签切换/时间线挂载/主线程卡顿」
#   cpu       运行一个冻结的「运行中」场景若干秒,检查本进程 CPU(验证流光/呼吸点等持续动画的开销)
#   resize    窗口宽度 1400↔900 逐帧往返缩放 N 次(OMA_RESIZE_SWEEP),汇总「缩放基准」
#   drag      逐帧拖动项目栏/工具栏/底栏/编辑分屏(OMA_DRAG_SWEEP=sidebar|tools|bottom|dock),汇总「拖分栏基准」
#   scroll    对会话流逐帧上下滚动 N 个来回(OMA_SCROLL_SWEEP),汇总「滚动基准」
#   stream    运行演示场景(流式输出)并汇总主线程卡顿
#   all       依次执行 interact 与 cpu(默认;resize/drag/scroll/stream 需单独指定,目前只记录不设门槛)
# 用法: Scripts/perf-ui.sh [interact|cpu|resize|drag|scroll|stream|all] [--build] [--sessions N] [--toggles M] [--cpu-seconds S] [--scenario 名]
#   --heavy N 额外生成 N 个压测 Skill(模拟真实 ~/.claude 有上千个技能/插件文件时的配置加载开销)
#   --sweeps N 扫描往返次数(resize/scroll,默认 3)
#   --build   先 Scripts/bundle.sh release(验收以 release 为准;不加则使用已有 build/OhMyAgent.app)
# 阈值见 `perf-report.py ui`;可用环境变量覆盖:UI_PANEL_AVG_MS UI_PANEL_HITCHES UI_PANEL_MAX_MS UI_FIRST_FRAME_MS
#   UI_COLD_OPEN_MS UI_WARM_SWITCH_MS UI_HITCH_MS UI_RUN_CPU
set -uo pipefail
source "${0:A:h}/lib-kill.sh"
cd "$(dirname "$0")/.."
MODE="all"; BUILD=""; SWEEPS=3; SESSIONS=6; TOGGLES=12; CPU_SECONDS=45; SCENARIO="states-frozen"; HEAVY=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    interact|cpu|resize|drag|scroll|stream|all) MODE="$1" ;;
    --sweeps) SWEEPS="${2:-3}"; shift ;;
    --build) BUILD="1" ;;
    --sessions) SESSIONS="${2:-6}"; shift ;;
    --toggles) TOGGLES="${2:-12}"; shift ;;
    --cpu-seconds) CPU_SECONDS="${2:-45}"; shift ;;
    --scenario) SCENARIO="${2:-states-frozen}"; shift ;;
    --heavy) HEAVY="${2:-800}"; shift ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
  shift
done
[[ -n "$BUILD" ]] && Scripts/bundle.sh release
APP="build/OhMyAgent.app"
[[ -d "$APP" ]] || { echo "没有 $APP,请先 Scripts/bundle.sh release 或加 --build" >&2; exit 2; }
export OMA_LOG_DIR="${OMA_LOG_DIR:-$HOME/Library/Logs/OhMyAgent}"
STATUS=0

# 启动演示版并返回 pid。参数: 其余为 --env 键值
launch() {
  killDemoApp; sleep 1
  local extra=(); [[ -n "$HEAVY" ]] && extra=(--env OMA_DEMO_EXTRA_SKILLS="$HEAVY")
  open -g -n "$APP" "${extra[@]}" --env OMA_DEMO=1 --env OMA_DEMO_RESET=1 --env OMA_PROJECT_ROOT="$PWD" --env OMA_PERF_SAMPLE_SECONDS=5 --env OMA_HITCH_SAMPLE=1 "$@"
  local pid=""
  for _ in {1..40}; do pid="$(pgrep -f "$PWD/$APP/Contents/MacOS/OhMyAgent" | head -1 || true)"; [[ -n "$pid" ]] && break; sleep 0.5; done
  echo "$pid"
}

# 阈值参数
thresholds() {
  echo --panel-avg-ms "${UI_PANEL_AVG_MS:-17.5}" --panel-hitches "${UI_PANEL_HITCHES:-1}" --panel-max-ms "${UI_PANEL_MAX_MS:-40}" \
       --first-frame-ms "${UI_FIRST_FRAME_MS:-120}" --cold-open-ms "${UI_COLD_OPEN_MS:-150}" --warm-switch-ms "${UI_WARM_SWITCH_MS:-50}" \
       --hitch-ms "${UI_HITCH_MS:-250}" --run-cpu "${UI_RUN_CPU:-15}"
}

if [[ "$MODE" == interact || "$MODE" == all ]]; then
  echo "== 交互基准:冷打开 $SESSIONS 个会话 → 热切换 → 左右侧栏各 $TOGGLES 次 =="
  PID="$(launch --env OMA_SWITCH_SESSIONS="$SESSIONS" --env OMA_SWITCH_DELAY=4 --env OMA_TOGGLE_LEFT=1 --env OMA_TOGGLE_RIGHT=1 --env OMA_TOGGLE_COUNT="$TOGGLES")"
  [[ -n "$PID" ]] || { echo "应用没有启动" >&2; exit 1; }
  # 左栏循环结束后才轮到右栏;总时长 ≈ 冷打开 + 热切换 + 2×M×1.5s,留足余量,最多等 300 秒
  WAIT=$(( 4 + SESSIONS * 3 + SESSIONS * 2 + 4 + 2 * TOGGLES * 3 / 2 + 15 ))
  echo "等待约 ${WAIT}s…"
  for ((i = 0; i < WAIT && i < 300; i++)); do
    kill -0 "$PID" 2>/dev/null || { echo "应用已退出(崩溃?)" >&2; exit 1; }
    sleep 1
  done
  python3 -I Scripts/perf-report.py ui --pid "$PID" $(thresholds) || STATUS=1
  killDemoApp
fi

if [[ "$MODE" == cpu || "$MODE" == all ]]; then
  echo; echo "== CPU 基准:运行中场景 $SCENARIO,持续 ${CPU_SECONDS}s =="
  PID="$(launch --env OMA_DEMO_SCENARIO="$SCENARIO" --env OMA_AUTOALLOW=1)"
  [[ -n "$PID" ]] || { echo "应用没有启动" >&2; exit 1; }
  sleep "$CPU_SECONDS"
  kill -0 "$PID" 2>/dev/null || { echo "应用已退出(崩溃?)" >&2; exit 1; }
  python3 -I Scripts/perf-report.py ui --pid "$PID" --cpu-only $(thresholds) 2>&1 | sed -n '/== CPU ==/,$p' || true
  python3 -I Scripts/perf-report.py ui --pid "$PID" --cpu-only $(thresholds) >/dev/null 2>&1 || STATUS=1
  killDemoApp
fi
# 流畅度基准:启动演示版跑指定场景(长会话)与扫描钩子,等日志出现「基准阶段 … 结束」后汇总(只记录,不设门槛)
sweep_run() {
  local label="$1"; shift
  echo; echo "== 流畅度基准:$label =="
  local pid; pid="$(launch --env OMA_DEMO_SCENARIO="${SCENARIO_LONG:-markdown-edge}" --env OMA_AUTOALLOW=1 "$@")"
  [[ -n "$pid" ]] || { echo "应用没有启动" >&2; STATUS=1; return; }
  # 场景运行 + 1.5s 稳定 + 扫描耗时(每帧约 16ms),最多等 120 秒
  for ((i = 0; i < 120; i++)); do
    kill -0 "$pid" 2>/dev/null || { echo "应用已退出(崩溃?)" >&2; STATUS=1; return; }
    sleep 1
    [[ $i -ge 12 ]] && python3 -I Scripts/perf-report.py ui --pid "$pid" --sweep-only 2>/dev/null | grep -q "帧数" && break
  done
  python3 -I Scripts/perf-report.py ui --pid "$pid" --sweep-only
  killDemoApp
}

[[ "$MODE" == resize ]] && sweep_run "窗口缩放 ${SWEEPS} 个来回" --env OMA_RESIZE_SWEEP="$SWEEPS"
if [[ "$MODE" == drag ]]; then
  for kind in sidebar tools bottom; do sweep_run "拖分栏 $kind" --env OMA_DRAG_SWEEP="$kind"; done
  sweep_run "拖分栏 dock(编辑区分屏)" --env OMA_DRAG_SWEEP=dock --env OMA_OPEN_FILE="$PWD/README.md" --env OMA_SPLIT=right
fi
[[ "$MODE" == scroll ]] && sweep_run "会话流滚动 ${SWEEPS} 个来回" --env OMA_SCROLL_SWEEP="$SWEEPS"
if [[ "$MODE" == stream ]]; then
  echo; echo "== 流式输出:运行场景 ${SCENARIO_LONG:-markdown-edge} =="
  PID="$(launch --env OMA_DEMO_SCENARIO="${SCENARIO_LONG:-markdown-edge}" --env OMA_AUTOALLOW=1)"
  [[ -n "$PID" ]] || { echo "应用没有启动" >&2; exit 1; }
  sleep 30
  kill -0 "$PID" 2>/dev/null || { echo "应用已退出(崩溃?)" >&2; exit 1; }
  python3 -I Scripts/perf-report.py ui --pid "$PID" | sed -n '/== 主线程卡顿/,$p'
  killDemoApp
fi
exit $STATUS
