#!/bin/zsh
# @author ixxxxoooo
# 重启应用:结束旧的应用与 Agent 子进程 → 重新构建 → 启动。
# 用法: Scripts/restart.sh [dev|debug|release]   (默认 dev:只重启开发版,不影响稳定版)
#   设置 OMA_AGENT=fake 可使用脚本化 Agent;OMA_DEMO=1 进入演示模式
# 隔离:只结束「开发版」进程及其子进程;稳定版(/Applications 里的 OhMyAgent)及其 Agent 不受影响。
set -euo pipefail
cd "$(dirname "$0")/.."
MODE="${1:-dev}"
if [[ "$MODE" == "dev" ]]; then
  APP="build/OhMyAgent Dev.app"; BUNDLE_ID="com.ixxxxoooo.OhMyAgent.dev"
else
  APP="build/OhMyAgent.app"; BUNDLE_ID="com.ixxxxoooo.OhMyAgent"
fi

# 按可执行文件所在的 .app 路径精确匹配,避免误杀另一个身份的同名进程
APP_ABS="$PWD/$APP"
for pid in $(pgrep -x OhMyAgent 2>/dev/null || true); do
  exe="$(ps -o command= -p "$pid" 2>/dev/null || true)"
  [[ "$exe" == "$APP_ABS/"* ]] || continue
  # 先结束该应用的子进程(Agent 适配器、FakeAgent),再结束应用本身
  for child in $(pgrep -P "$pid" 2>/dev/null || true); do pkill -P "$child" 2>/dev/null || true; kill "$child" 2>/dev/null || true; done
  kill "$pid" 2>/dev/null || true
done
sleep 0.5

Scripts/bundle.sh "$MODE"
env -u TZ open -n "$APP" --env OMA_AGENT="${OMA_AGENT:-}" --env OMA_DEMO="${OMA_DEMO:-}" --env OMA_PROJECT_ROOT="$PWD"
echo "已启动 $BUNDLE_ID"
