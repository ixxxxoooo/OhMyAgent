#!/bin/zsh
# @author ixxxxoooo
# 日志快捷命令。
#   Scripts/logs.sh tail [正则]      实时查看当前日志文件(可选只看匹配的行,如 "WARN|ERROR")
#   Scripts/logs.sh os               通过统一日志实时查看(log stream)
#   Scripts/logs.sh grep <关键字>    在全部日志文件中搜索
#   Scripts/logs.sh open             在 Finder 中打开日志目录
#   Scripts/logs.sh last [行数]      输出最近的日志行(默认 200)
#   性能分析(默认只看最近一次启动的那个进程;加 --all 看全部,--pid N 指定进程):
#   Scripts/logs.sh report           整体画像:内存/CPU、告警计数、启动阶段、TTFT、代理流、耗时 Top、容量峰值
#   Scripts/logs.sh mem              内存与 CPU 时序(本进程/子进程/线程/fd)
#   Scripts/logs.sh slow             perf/git/editor/lsp 的 WARN 与 ERROR
#   Scripts/logs.sh turn <标识>      按会话前缀(如 1faaa441)串起相关日志
export LC_ALL=en_US.UTF-8
DIR="$HOME/Library/Logs/OhMyAgent"
HERE="${0:A:h}"
latest() { command ls -t "$DIR"/oma-[0-9]*.log 2>/dev/null | head -1 }
case "${1:-tail}" in
  tail)
    FILE="$(latest)"
    [[ -z "$FILE" ]] && { echo "还没有日志文件:$DIR"; exit 1; }
    if [[ -n "${2:-}" ]]; then tail -n 200 -F "$FILE" | grep -a --line-buffered -E "${2}"; else tail -n 200 -F "$FILE"; fi ;;
  os)
    log stream --level debug --predicate 'subsystem == "com.ixxxxoooo.OhMyAgent"' ;;
  grep)
    [[ -z "${2:-}" ]] && { echo "用法: logs.sh grep <关键字>"; exit 2; }
    grep -a -n -- "$2" "$DIR"/*.log ;;
  open)
    open "$DIR" ;;
  last)
    tail -n "${2:-200}" "$(latest)" ;;
  report|mem|slow|turn)
    exec python3 -I "$HERE/perf-report.py" "$@" ;;
  *)
    sed -n '2,16p' "$0"; exit 2 ;;
esac
