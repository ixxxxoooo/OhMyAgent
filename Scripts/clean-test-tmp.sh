#!/bin/zsh
# @author ixxxxoooo
# 清理单元测试在系统临时目录里遗留的目录。
# 用法:
#   Scripts/clean-test-tmp.sh --dry-run          只统计不删除(清理历史遗留前先看一眼)
#   Scripts/clean-test-tmp.sh                    清理全部历史遗留
#   Scripts/clean-test-tmp.sh --since <标记文件>  只清理该标记文件之后创建的(Scripts/test.sh 使用)
# 只删除同时满足「已知测试前缀 + UUID 后缀」的条目,以及 Swift 工具链遗留的空 TemporaryDirectory.*(只含 .keep-directory),
# 不会碰其他应用的文件。
TEMP_DIR="$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null)"
[[ -d "$TEMP_DIR" ]] || TEMP_DIR="${TMPDIR:-/tmp}"
TEMP_DIR="${TEMP_DIR%/}"
DRY=""
SINCE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --since) SINCE="${2:-}"; shift ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
  shift
done
# 已知的测试目录前缀(新增测试若使用新前缀,请加在这里)
PREFIXES='(oma-[a-z0-9-]+|lsp-it|agent-install|agent-model|drop|idx|themes|wb)'
UUID='[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}'
# 直接位于临时目录下:前缀-UUID[.扩展];以及 SwiftPM 为测试目录生成的锁文件(_private_var_..._T_lsp-it-UUID_...)
DIR_RE="^${PREFIXES}-${UUID}(\\..*)?\$"
LOCK_RE="^_private_var_folders_.*_T_(lsp-it)-${UUID}_.*"
FIND_ARGS=("$TEMP_DIR" -maxdepth 1 -mindepth 1)
[[ -n "$SINCE" ]] && FIND_ARGS+=(-newer "$SINCE")
removed=0 empties=0
while IFS= read -r entry; do
  name="${entry:t}"
  if [[ "$name" =~ $DIR_RE || "$name" =~ $LOCK_RE ]]; then
    [[ -n "$DRY" ]] || rm -rf "$entry"
    removed=$((removed + 1))
  elif [[ "$name" =~ '^TemporaryDirectory\.[A-Za-z0-9]{6}$' && -d "$entry" ]]; then
    # Swift 工具链(构建/测试)遗留的临时目录:空,或只含一个 0 字节的 .keep-directory。
    # 其他内容一律不碰;全量清理时还要求超过 1 小时未修改,避免误删正在使用的目录。
    content="$(command ls -A "$entry" 2>/dev/null)"
    [[ -z "$content" || "$content" == ".keep-directory" ]] || continue
    if [[ -z "$SINCE" && -z "$(/usr/bin/find "$entry" -maxdepth 0 -mmin +60 2>/dev/null)" ]]; then continue; fi
    [[ -n "$DRY" ]] || rm -rf "$entry"
    empties=$((empties + 1))
  fi
done < <(/usr/bin/find "${FIND_ARGS[@]}" 2>/dev/null)
echo "${DRY:+[dry-run] }测试临时目录 ${removed} 个,Swift 工具链遗留的空 TemporaryDirectory ${empties} 个" >&2
