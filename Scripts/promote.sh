#!/bin/zsh
# @author ixxxxoooo
# 把当前代码构建为稳定版并安装到 /Applications/OhMyAgent.app。
# ⚠️ 必须在系统 Terminal.app 里运行,不要在稳定版 OhMyAgent 内的终端运行(脚本会退出稳定版)。
# 用法: Scripts/promote.sh
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "${TERM_PROGRAM:-}" == "OhMyAgent" ]]; then
  echo "错误:请在系统 Terminal.app 中运行,不要在 OhMyAgent 内置终端里运行"; exit 1
fi
Scripts/bundle.sh release
osascript -e 'tell application id "com.ixxxxoooo.OhMyAgent" to quit' 2>/dev/null || true
sleep 1
rm -rf /Applications/OhMyAgent.app
cp -R build/OhMyAgent.app /Applications/OhMyAgent.app
open /Applications/OhMyAgent.app
echo "稳定版已更新:/Applications/OhMyAgent.app"
