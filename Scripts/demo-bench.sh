#!/bin/zsh
# @author ixxxxoooo
# 演示空间性能基准:构建 → 以演示模式启动(OMA_DEMO_BENCH 自动跑完所有度量)→ 等待结果 JSON → 打印 Markdown 汇总 → 退出应用。
# 覆盖:项目打开与 1 万文件索引、2000/800 轮长会话加载、跨叶子复制、Markdown/表格/图表/Mermaid/代码渲染、
# 模型与引擎切换并恢复会话、运行期真实内存曲线(0.5 秒采样,写入 JSON)。
#
# 用法: Scripts/demo-bench.sh [选项]
#   --only <分类,...>  只跑指定分类:open,load,copy,render,switching,memory,ide,editor(默认 all)
#   --turns <N>        长会话轮数(默认 2000;设 OMA_TIMELINE_TURNS)
#   --out <文件>       结果 JSON 路径(默认 /tmp/oma-demo-metrics.json;同名 .md 为汇总)
#   --reset            先重建演示沙盒
#   --no-build         跳过构建(沿用 build/OhMyAgent.app)
#   --release          用 release 构建跑(IDE 预算以 release 为准,debug 明显偏慢)
#   --check-baseline   跑完后与 Scripts/perf-baseline.json 比对 ide.* 指标,回归时以 4 退出(见 Scripts/ide-bench-check.py)
#   --update-baseline  跑完后把本次 ide.* 指标写成新基线
#   --keep             跑完后不退出应用(可在「演示指标」标签里查看曲线)
#   --timeout <秒>     等待结果的最长时间(默认 900)
set -euo pipefail
source "${0:A:h}/lib-kill.sh"
cd "$(dirname "$0")/.."

ONLY="all"
OUT="/tmp/oma-demo-metrics.json"
BUILD=1
RESET=""
KEEP=""
MODE="debug"
CHECK=""
UPDATE=""
TURNS=""
TIMEOUT=900
while [[ $# -gt 0 ]]; do
  case "$1" in
    --only) ONLY="${2:?缺少分类}"; shift ;;
    --turns) TURNS="${2:?缺少轮数}"; shift ;;
    --out) OUT="${2:?缺少文件}"; shift ;;
    --timeout) TIMEOUT="${2:?缺少秒数}"; shift ;;
    --reset) RESET="1" ;;
    --no-build) BUILD="" ;;
    --keep) KEEP="1" ;;
    --release) MODE="release" ;;
    --check-baseline) CHECK="1" ;;
    --update-baseline) UPDATE="1" ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
  shift
done

killDemoApp
sleep 0.3
[[ -n "$BUILD" ]] && Scripts/bundle.sh "$MODE"
rm -f "$OUT" "${OUT%.json}.md"

ARGS=(--env OMA_DEMO=1 --env "OMA_PROJECT_ROOT=$PWD" --env "OMA_DEMO_BENCH=$ONLY" --env "OMA_DEMO_BENCH_OUT=$OUT")
[[ -n "$RESET" ]] && ARGS+=(--env OMA_DEMO_RESET=1)
[[ -z "$KEEP" ]] && ARGS+=(--env OMA_DEMO_BENCH_EXIT=1)
[[ -n "$TURNS" ]] && ARGS+=(--env "OMA_TIMELINE_TURNS=$TURNS")
[[ -n "${OMA_IDE_SOAK_SECONDS:-}" ]] && ARGS+=(--env "OMA_IDE_SOAK_SECONDS=$OMA_IDE_SOAK_SECONDS")
[[ -n "${OMA_DEMO_ROOT:-}" ]] && ARGS+=(--env "OMA_DEMO_ROOT=$OMA_DEMO_ROOT")
# 编辑器引擎对照(native2 / textkit):用于同一套 ide.* 基准的 A/B
[[ -n "${OMA_EDITOR_ENGINE:-}" ]] && ARGS+=(--env "OMA_EDITOR_ENGINE=$OMA_EDITOR_ENGINE")
env -u TZ open -g -n build/OhMyAgent.app "${ARGS[@]}"
echo "已启动演示基准(分类:$ONLY),等待结果写入 $OUT …"

waited=0
while [[ ! -f "${OUT%.json}.md" ]]; do
  sleep 2; waited=$((waited + 2))
  if (( waited >= TIMEOUT )); then echo "等待超时(${TIMEOUT}s),请查看应用内「演示指标」标签与日志" >&2; exit 1; fi
done
echo
cat "${OUT%.json}.md"
echo "JSON: $OUT"
# 存在失败项时以非零状态退出,便于脚本化回归
# 超过两倍预算或运行失败的项目:带 --check-baseline 时由基线检查(含「已知差距」登记)统一裁决,否则直接按预算失败
if [[ -n "$UPDATE" ]]; then python3 Scripts/ide-bench-check.py update "$OUT"; fi
BUDGET_FAIL=0
python3 - "$OUT" <<'PY' || BUDGET_FAIL=1
import json, sys
data = json.load(open(sys.argv[1]))
failed = [m for m in data["metrics"] if m.get("budget") is not None and (m.get("value") is None or m["value"] > m["budget"] * 2)]
sys.exit(1 if failed else 0)
PY
if [[ -n "$CHECK" ]]; then
  python3 Scripts/ide-bench-check.py check "$OUT" || exit 4
  exit 0
fi
if (( BUDGET_FAIL )); then echo "存在超过两倍预算或运行失败的项目" >&2; exit 3; fi
