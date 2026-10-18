#!/bin/zsh
# @author ixxxxoooo
# 演示模式「无人值守导览」:逐个步骤启动演示模式应用(不抢焦点)→ 等待 → 对应用窗口截图 → 退出,
# 把截图汇总到一个目录,用于一次性浏览/回归所有工具卡、子 Agent、状态、Git 视图与设置页。
#
# 用法: Scripts/demo-tour.sh [选项] [步骤名前缀...]
#   --out <目录>   截图输出目录(默认 /tmp/oma-demo-tour)
#   --wait <秒>    每步等待秒数的基准倍率(默认 1,机器慢时调大,如 --wait 2)
#   --reset        第一步前重建演示沙盒
#   --no-build     跳过构建(沿用 build/OhMyAgent.app)
#   --list         只列出全部步骤名
#   OMA_THEME=<主题 id>  环境变量:以指定主题运行(如 paper-light、paper-dark、cursor-light),用于主题对比截图
#   步骤名前缀     只跑名字以其开头的步骤,如 `scenario-tools` `git-` `settings-`
# 说明:
#   - 禁止使用 osascript 发送按键;全部通过 OMA_* 调试钩子驱动,截图用 screencapture -l<窗口号>。
#   - 交互场景(permissions/plan-approval/ask/changes)与冻结场景只截「等待用户操作/冻结」时的画面。
#   - 截图保留在输出目录,看完请自行删除。
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="/tmp/oma-demo-tour"
WAIT_SCALE=1
RESET=""
BUILD=1
LIST=""
PREFIXES=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) OUT="${2:?缺少目录}"; shift ;;
    --wait) WAIT_SCALE="${2:?缺少倍率}"; shift ;;
    --reset) RESET="1" ;;
    --no-build) BUILD="" ;;
    --list) LIST="1" ;;
    -*) echo "未知参数: $1" >&2; exit 2 ;;
    *) PREFIXES+=("$1") ;;
  esac
  shift
done

ROOT="${OMA_DEMO_ROOT:-$HOME/Library/Caches/OhMyAgent/Demo}"
ATLAS="$ROOT/projects/atlas-web"
LOGO="$ATLAS/assets/logo.png"

# ---- 步骤表:名称|等待秒数|环境变量(以 ; 分隔的 KEY=VALUE 列表,值里可含空格,但不能含 ; 或 |) ----
typeset -a STEPS
add() { STEPS+=("$1|$2|$3"); }

# 1) 场景:自动跑完的(展开所有工具卡)
for s in tools-files tools-shell tools-web-mcp canvas tools-browser tools-image tools-plan-todo subagents subagents-parallel subagents-background \
         states-notices states-errors states-streaming roles user-variants markdown markdown-edge mermaid showcase-tour; do
  add "scenario-$s" 12 "OMA_DEMO_SCENARIO=$s;OMA_EXPAND_ALL=1"
done
for s in errors-refusal errors-max-tokens errors-rate-limit errors-auth errors-render-failed errors-unknown; do
  add "scenario-$s" 10 "OMA_DEMO_SCENARIO=$s;OMA_EXPAND_ALL=1"
done
add "scenario-usage-limits" 12 "OMA_DEMO_SCENARIO=usage-limits;OMA_EXPAND_ALL=1;OMA_USAGE_PANEL=1"
add "scenario-context-compact" 12 "OMA_DEMO_SCENARIO=context-compact;OMA_EXPAND_ALL=1"
add "scenario-errors-premature-end" 10 "OMA_DEMO_SCENARIO=errors-premature-end;OMA_EXPAND_ALL=1"
add "scenario-modes-matrix" 14 "OMA_DEMO_SCENARIO=modes-matrix;OMA_EXPAND_ALL=1"
add "scenario-long-running" 14 "OMA_DEMO_SCENARIO=long-running;OMA_EXPAND_ALL=1"
add "scenario-terminal" 12 "OMA_DEMO_SCENARIO=terminal;OMA_EXPAND_ALL=1"
add "scenario-all" 60 "OMA_DEMO_SCENARIO=all;OMA_EXPAND_ALL=1"
# 2) 场景:冻结与交互(只截停住的画面)
for s in states-working states-frozen permissions permissions-variants plan-approval ask ask-variants ask-forms changes; do
  add "scenario-$s" 10 "OMA_DEMO_SCENARIO=$s;OMA_EXPAND_ALL=1"
done
add "scenario-plan-approval-built" 12 "OMA_DEMO_SCENARIO=plan-approval;OMA_AUTOALLOW=1;OMA_EXPAND_ALL=1"
add "scenario-permissions-autoallow" 12 "OMA_DEMO_SCENARIO=permissions;OMA_AUTOALLOW=1;OMA_EXPAND_ALL=1"
# 3) 会话流相关
add "chat-collapsed" 10 "OMA_DEMO_SCENARIO=tools-files"
add "chat-usage-panel" 10 "OMA_DEMO_SCENARIO=states-notices;OMA_USAGE_PANEL=1"
add "chat-subagent-tab" 12 "OMA_DEMO_SCENARIO=subagents;OMA_OPEN_SUBAGENT=a_explore-r1"
add "chat-image-send" 10 "OMA_ATTACH_IMAGE=$LOGO;OMA_AUTOSEND=看看这张图 /demo-roles"
add "chat-draft-image" 8 "OMA_ATTACH_IMAGE=$LOGO;OMA_DRAFT=帮我看看这张图"
add "chat-branch-menu" 8 "OMA_BRANCH_MENU=1"
add "chat-palette-commands" 8 "OMA_PALETTE=commands;OMA_PALETTE_QUERY=demo"
add "chat-palette-files" 10 "OMA_PALETTE=files;OMA_PALETTE_QUERY=router"
# 4) 工作台与 Git
add "git-panel" 10 "OMA_RIGHT_PANE=git"
add "git-changes-panel" 10 "OMA_RIGHT_PANE=changes"
add "git-files-panel" 8 "OMA_RIGHT_PANE=files"
add "git-search-panel" 10 "OMA_RIGHT_PANE=search;OMA_SEARCH_QUERY=Router"
add "git-diff" 10 "OMA_OPEN_DIFF=$ATLAS/Sources/AtlasCore/Cache.swift;OMA_SHOW_RIGHT=1;OMA_RIGHT_PANE=git"
add "git-history" 10 "OMA_OPEN_HISTORY=1"
add "git-file-history" 10 "OMA_OPEN_HISTORY=$ATLAS/Sources/AtlasCore/Router.swift"
add "git-blame" 10 "OMA_OPEN_BLAME=$ATLAS/Sources/AtlasCore/Router.swift"
add "git-merge-conflict" 12 "OMA_OPEN_PROJECTS=$ROOT/projects/merge-lab;OMA_RIGHT_PANE=git"
add "git-clean-repo" 12 "OMA_OPEN_PROJECTS=$ROOT/projects/notes-cli;OMA_RIGHT_PANE=git"
add "git-not-a-repo" 12 "OMA_OPEN_PROJECTS=$ROOT/projects/legacy-api;OMA_RIGHT_PANE=git"
add "git-empty-project" 12 "OMA_OPEN_PROJECTS=$ROOT/projects/empty-project;OMA_RIGHT_PANE=files"
add "editor-file" 10 "OMA_OPEN_FILE=$ATLAS/Sources/AtlasCore/Router.swift;OMA_OPEN_LINE=12"
add "editor-split-right" 10 "OMA_OPEN_FILE=$ATLAS/README.md;OMA_SPLIT=right"
add "editor-mermaid" 10 "OMA_OPEN_MERMAID=graph TD\\nA[开始]-->B{判断}\\nB-->C[结束]"
add "terminal-tab" 12 "OMA_OPEN_TERMINAL=1;OMA_TERM_INPUT=git status\\n"
add "bottom-panel" 8 "OMA_SHOW_BOTTOM=1;OMA_BOTTOM_PANE=terminal"
# 5) 设置页
for p in general appearance shortcuts agent providers prompts network permissions trust agentExtensions editor terminal usage privacy advanced diagnostics; do
  add "settings-$p" 8 "OMA_OPEN_SETTINGS=1;OMA_SETTINGS_PAGE=$p"
done
# 5a) 画布标签页(演示沙盒预置了 demo-quarterly-report)
add "canvas-tab" 10 "OMA_OPEN_CANVAS=demo-quarterly-report"
# 5b) 自定义页(原设置页「扩展」分组合并而来)
for f in all mcp skills subagents hooks plugins rules; do
  add "customize-$f" 8 "OMA_OPEN_CUSTOMIZE=$f"
done

if [[ -n "$LIST" ]]; then
  for entry in "${STEPS[@]}"; do print -r -- "${entry%%|*}"; done
  exit 0
fi

# 过滤步骤
typeset -a SELECTED
for entry in "${STEPS[@]}"; do
  name="${entry%%|*}"
  if (( ${#PREFIXES[@]} == 0 )); then SELECTED+=("$entry"); continue; fi
  for prefix in "${PREFIXES[@]}"; do [[ "$name" == "$prefix"* ]] && { SELECTED+=("$entry"); break; }; done
done
(( ${#SELECTED[@]} > 0 )) || { echo "没有匹配的步骤(用 --list 查看)" >&2; exit 2; }

[[ -n "$BUILD" ]] && Scripts/bundle.sh debug
mkdir -p "$OUT"

# 截取应用主窗口(取面积最大的可见窗口;应用还会有一个全透明的覆盖层窗口,需排除),文件名 <步骤>.png
shoot() {
  local name="$1"
  python3 - "$OUT" "$name" <<'PY'
import subprocess, sys
import Quartz
out, name = sys.argv[1], sys.argv[2]
best, area = None, 0
for w in Quartz.CGWindowListCopyWindowInfo(Quartz.kCGWindowListOptionAll, Quartz.kCGNullWindowID):
    b = w["kCGWindowBounds"]
    if w.get("kCGWindowOwnerName") == "OhMyAgent" and w.get("kCGWindowLayer") == 0 and w.get("kCGWindowAlpha", 1) > 0 and w.get("kCGWindowName", "x") != "":
        a = b["Width"] * b["Height"]
        if b["Width"] > 400 and b["Height"] > 300 and a > area:
            best, area = w["kCGWindowNumber"], a
if best is None:
    print(0)
else:
    subprocess.run(["screencapture", "-x", "-o", "-l%d" % best, "%s/%s.png" % (out, name)])
    print(1)
PY
}

stop_app() {
  pkill -x OhMyAgent 2>/dev/null || true
  pkill -x FakeAgent 2>/dev/null || true
  sleep 0.5
}

first=1
for entry in "${SELECTED[@]}"; do
  name="${entry%%|*}"; rest="${entry#*|}"
  wait_s="${rest%%|*}"; envs="${rest#*|}"
  stop_app
  # 每步从干净的工作台状态开始(workbench.json 缺失时由 DemoSeed 重新预置),避免上一步的标签页被恢复
  [[ -z "$first" || -z "$RESET" ]] && rm -f "$ROOT/support/workbench.json"
  args=(--env OMA_DEMO=1 --env "OMA_DEMO_ROOT=$ROOT" --env "OMA_PROJECT_ROOT=$PWD")
  if [[ -n "$first" && -n "$RESET" ]]; then args+=(--env OMA_DEMO_RESET=1); fi
  [[ -n "${OMA_THEME:-}" ]] && args+=(--env "OMA_THEME=$OMA_THEME")   # 指定主题 id 做主题对比截图
  for kv in ${(s:;:)envs}; do
    args+=(--env "$kv")   # 值里的 \n 原样交给应用解释
  done
  open -g -n build/OhMyAgent.app "${args[@]}"
  if [[ -n "$first" ]]; then sleep $(( 25 * WAIT_SCALE )); first=""; fi
  sleep $(( wait_s * WAIT_SCALE ))
  count="$(shoot "$name")"
  if [[ "$count" == "1" ]]; then echo "[$name] ✔ $OUT/$name.png"; else echo "[$name] ✘ 未找到窗口"; fi
done
stop_app
echo "完成:$OUT(看完请删除)"
