#!/bin/zsh
# @author ixxxxoooo
# 公共函数:只结束「稳定版/演示版」build/OhMyAgent.app 及其子进程,绝不碰开发版(build/OhMyAgent Dev.app)。
# 背景:开发版内的 Agent 会话若执行 demo.sh,按进程名 pkill 会把自己所在的开发版一并杀掉。
# 用法: source "$(dirname "$0")/lib-kill.sh"; killDemoApp

# 结束 build/OhMyAgent.app 的进程及其子进程(Agent 适配器、FakeAgent)。
# 参数: 无(以脚本所在仓库根目录定位 .app 绝对路径)
# 返回: 恒为 0
killDemoApp() {
  local root app pid exe child
  root="$(cd "$(dirname "${(%):-%x}")/.." && pwd)"
  app="$root/build/OhMyAgent.app/"
  for pid in $(pgrep -x OhMyAgent 2>/dev/null || true); do
    exe="$(ps -o command= -p "$pid" 2>/dev/null || true)"
    [[ "$exe" == "$app"* ]] || continue
    for child in $(pgrep -P "$pid" 2>/dev/null || true); do
      pkill -P "$child" 2>/dev/null || true
      kill "$child" 2>/dev/null || true
    done
    kill "$pid" 2>/dev/null || true
  done
  return 0
}
