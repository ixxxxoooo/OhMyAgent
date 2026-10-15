#!/bin/zsh
# @author ygw
# 重启应用:结束旧的应用与 Agent 子进程 → 重新构建 → 启动。
# 用法: Scripts/restart.sh [debug|release]   (设置 OMA_AGENT=fake 可使用脚本化 Agent)
set -euo pipefail
cd "$(dirname "$0")/.."
pkill -x OhMyAgent 2>/dev/null || true
pkill -f "claude-agent-acp" 2>/dev/null || true
pkill -x FakeAgent 2>/dev/null || true
pkill -x OhMyAgentBridge 2>/dev/null || true
sleep 0.3
Scripts/bundle.sh "${1:-debug}"
open -n build/OhMyAgent.app --env OMA_AGENT="${OMA_AGENT:-}" --env OMA_PROJECT_ROOT="$PWD"
echo "已启动 OhMyAgent"
