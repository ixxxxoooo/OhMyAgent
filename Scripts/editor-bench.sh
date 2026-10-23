#!/bin/zsh
# @author ixxxxoooo
# 原生编辑器(native2)基准:以演示模式启动应用,只跑 `editor.*` 度量点(合成素材:5 万 / 100 万行 Swift),
# 对照 120Hz 预算(滚动 p50 ≤ 8.4ms / p99 ≤ 11ms / 掉帧 < 1%,输入 p95 ≤ 4ms / max ≤ 8ms,打开 ≤ 40/100/800ms,
# 增量语法 ≤ 2ms,补全浮层 ≤ 16ms,Agent 补丁 ≤ 5ms,100 万行内存 ≤ 2.5 倍文件)。
# 预算以 release 构建为准(debug 明显偏慢),默认 --release。
#
# 用法: Scripts/editor-bench.sh [选项]
#   --debug              用 debug 构建(仅冒烟,预算不可信)
#   --no-build           跳过构建(沿用 build/OhMyAgent.app)
#   --check-baseline     与 Scripts/perf-baseline.json 的 editor.* 比对,回归以 4 退出
#   --update-baseline    把本次 editor.* 写入基线(与 ide.* 合并,不互相覆盖)
#   --out <文件>         结果 JSON(默认 /tmp/oma-editor-bench.json)
#   --ab                 另输出与旧 TextKit 冻结基线(Scripts/editor-baseline-textkit.json)的对照表
# 注意:基准会在屏幕上放一个近乎透明的小窗口(显示链接需要被合成才会触发),运行期间请勿遮挡/锁屏。
set -euo pipefail
cd "$(dirname "$0")/.."

MODE="--release"
OUT="/tmp/oma-editor-bench.json"
PASS=()
AB=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --debug) MODE="" ;;
    --no-build) PASS+=(--no-build) ;;
    --check-baseline) PASS+=(--check-baseline) ;;
    --update-baseline) PASS+=(--update-baseline) ;;
    --out) OUT="${2:?缺少文件}"; shift ;;
    --ab) AB=1 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
  shift
done

STATUS=0
Scripts/demo-bench.sh --only editor ${MODE:+$MODE} --out "$OUT" --timeout 600 "${PASS[@]}" || STATUS=$?

if [[ -n "$AB" && -f "$OUT" ]]; then
  python3 - "$OUT" <<'PY'
import json, os, sys
result = {m["id"]: m for m in json.load(open(sys.argv[1]))["metrics"] if m["id"].startswith("editor.")}
legacy = json.load(open(os.path.join("Scripts", "editor-baseline-textkit.json")))["metrics"]
pairs = [("editor.open-50k", "ide.open-50k"), ("editor.scroll-p50", "ide.scroll-frame"), ("editor.typing-p95", "ide.typing-p95"),
         ("editor.typing-max", "ide.typing-max"), ("editor.syntax-incremental", "ide.syntax-incremental")]
print("\n| 指标 | native2 | 旧 TextKit(冻结基线) | 倍数 |\n| --- | --- | --- | --- |")
for new, old in pairs:
    if new in result and result[new].get("value") is not None and old in legacy:
        n, o = result[new]["value"], legacy[old]
        print(f"| {new} | {n:.2f} | {o:.2f} | {n / o:.2f}× |" if o else f"| {new} | {n:.2f} | — | — |")
PY
fi
exit $STATUS
