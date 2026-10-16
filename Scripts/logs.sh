#!/bin/zsh
# @author ixxxxoooo
# 日志快捷命令。
#   Scripts/logs.sh tail [级别]      实时查看当前日志文件(可选只看 WARN/ERROR 等关键字)
#   Scripts/logs.sh os               通过统一日志实时查看(log stream)
#   Scripts/logs.sh grep <关键字>    在全部日志文件中搜索
#   Scripts/logs.sh open             在 Finder 中打开日志目录
#   Scripts/logs.sh last [行数]      输出最近的日志行(默认 200)
DIR="$HOME/Library/Logs/OhMyAgent"
case "${1:-tail}" in
  tail)
    FILE="$(ls -t "$DIR"/oma-*.log 2>/dev/null | head -1)"
    [[ -z "$FILE" ]] && { echo "还没有日志文件:$DIR"; exit 1; }
    if [[ -n "${2:-}" ]]; then tail -n 200 -F "$FILE" | grep --line-buffered -E "${2}"; else tail -n 200 -F "$FILE"; fi ;;
  os)
    log stream --level debug --predicate 'subsystem == "com.ixxxxoooo.OhMyAgent"' ;;
  grep)
    [[ -z "${2:-}" ]] && { echo "用法: logs.sh grep <关键字>"; exit 2; }
    grep -n -- "$2" "$DIR"/*.log ;;
  open)
    open "$DIR" ;;
  last)
    FILE="$(ls -t "$DIR"/oma-*.log 2>/dev/null | head -1)"
    tail -n "${2:-200}" "$FILE" ;;
  *)
    sed -n '2,10p' "$0"; exit 2 ;;
esac
