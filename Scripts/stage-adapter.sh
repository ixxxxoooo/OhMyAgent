#!/bin/zsh
# @author ixxxxoooo
# 准备内置 ACP 适配器(claude-agent-acp):
#   1. 缺少 Vendor/acp/node_modules 时自动 `npm ci` 安装(不含 Agent SDK 的平台原生二进制,使用用户本机 claude);
#   2. 裁剪(去掉 sourcemap/类型声明/文档/平台二进制)后同步到暂存目录 build/acp-stage;
#   3. 仅当 package-lock.json 变化或暂存目录缺失时才重新生成,日常构建几乎零开销。
# 用法: Scripts/stage-adapter.sh   (成功后暂存目录为 build/acp-stage,供 bundle.sh 拷入 .app)
set -euo pipefail
cd "$(dirname "$0")/.."

STAGE="build/acp-stage"
STAMP="$STAGE/.lock-hash"
LOCK_HASH="$(shasum -a 256 Vendor/acp/package-lock.json | cut -d' ' -f1)"

if [[ -f "$STAMP" && "$(cat "$STAMP")" == "$LOCK_HASH" && -f "$STAGE/node_modules/@agentclientprotocol/claude-agent-acp/dist/index.js" ]]; then
  echo "适配器暂存目录已是最新:$STAGE"
  exit 0
fi

if [[ ! -f Vendor/acp/node_modules/@agentclientprotocol/claude-agent-acp/dist/index.js ]]; then
  command -v npm >/dev/null 2>&1 || { echo "错误:未找到 npm,无法安装内置适配器。请先安装 Node.js 22+"; exit 1; }
  echo "正在安装适配器依赖(Vendor/acp)…"
  # --omit=optional:跳过 Agent SDK 的平台原生二进制(约 240MB),运行时使用用户本机已安装的 claude
  (cd Vendor/acp && npm ci --no-audit --no-fund --ignore-scripts --omit=optional)
fi

mkdir -p "$STAGE"
rsync -a --delete \
  --exclude='*.map' --exclude='*.d.ts' --exclude='*.d.mts' --exclude='*.d.cts' \
  --exclude='*.md' --exclude='LICENSE*' --exclude='test' --exclude='tests' --exclude='__tests__' \
  --exclude='.github' --exclude='docs' --exclude='claude-agent-sdk-darwin-*' \
  --exclude='claude-agent-sdk-linux-*' --exclude='claude-agent-sdk-win32-*' \
  Vendor/acp/node_modules "$STAGE/"
cp Vendor/acp/package.json "$STAGE/"
echo "$LOCK_HASH" > "$STAMP"
echo "适配器已暂存:$STAGE($(du -sh "$STAGE" | cut -f1))"
