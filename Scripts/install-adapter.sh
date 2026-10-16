#!/bin/zsh
# @author ixxxxoooo
# 手动安装 ACP 适配器到 ~/Library/Application Support/OhMyAgent/acp(应用启动时会自动探测)。
# 正常情况下不需要运行本脚本:应用包已内置适配器,缺失时应用也会自动安装;仅在离线预装或自动安装失败时使用。
# 用法: Scripts/install-adapter.sh
set -euo pipefail
cd "$(dirname "$0")/.."

DEST="$HOME/Library/Application Support/OhMyAgent/acp"
VERSION="$(sed -n 's/.*"@agentclientprotocol\/claude-agent-acp": *"\^\{0,1\}\([0-9.]*\)".*/\1/p' Vendor/acp/package.json | head -1)"
command -v npm >/dev/null 2>&1 || { echo "错误:未找到 npm,请先安装 Node.js 22+"; exit 1; }

mkdir -p "$DEST"
echo "正在安装 claude-agent-acp@${VERSION:-latest} 到 $DEST …"
npm install --prefix "$DEST" --no-audit --no-fund --ignore-scripts --omit=optional "@agentclientprotocol/claude-agent-acp@${VERSION:-latest}"
echo "完成。重启或点击应用中的「重试」即可连接。"
