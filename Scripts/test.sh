#!/bin/zsh
# @author ixxxxoooo
# 运行单元测试,并在结束后清理测试在系统临时目录里留下的目录。
# 背景:测试里有大量 NSTemporaryDirectory()/temporaryDirectory 下的临时目录(名字形如 `oma-ws-<UUID>`)没有逐个清理,
# 长期累积到近 3 万个条目。macOS 上 NSTemporaryDirectory() 不读 TMPDIR 环境变量,无法用私有目录隔离,
# 所以改为:测试开始前打时间标记,结束后只删除「名字是 前缀-UUID 且在标记之后创建」的目录,不会误伤其他文件。
# 清理逻辑见 Scripts/clean-test-tmp.sh;清理历史遗留:Scripts/clean-test-tmp.sh
# 用法: Scripts/test.sh [swift test 的参数...]
cd "$(dirname "$0")/.."
TEMP_DIR="$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null)"
[[ -d "$TEMP_DIR" ]] || TEMP_DIR="${TMPDIR:-/tmp}"
MARKER="$(mktemp "${TEMP_DIR%/}/oma-test-marker.XXXXXX")" || exit 1
cleanup() {
  Scripts/clean-test-tmp.sh --since "$MARKER"
  rm -f "$MARKER"
}
trap cleanup EXIT INT TERM
swift test "$@"
