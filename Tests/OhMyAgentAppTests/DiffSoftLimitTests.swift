// @author ixxxxoooo
// 差异软上限:按行截断(单个超大块也只渲染前若干行),未超限或已展开时原样返回。

import DiffKit
import Testing

@testable import OhMyAgentApp

@Suite("差异软上限")
struct DiffSoftLimitTests {
    private func diff(lines: Int) -> FileDiff {
        let old = "a\nb\n"
        let new = old + (0..<lines).map { "line\($0)\n" }.joined()
        return LineDiff.diff(old: old, new: new)
    }

    @Test("单个超大块按行截断,不再整块渲染")
    func truncatesInsideHunk() {
        let file = diff(lines: 3749)
        let total = file.hunks.reduce(0) { $0 + $1.lines.count }
        let shown = DiffSoftLimit.visible(file.hunks, total: total, showAll: false)
        #expect(shown.reduce(0) { $0 + $1.lines.count } <= DiffSoftLimit.lines)
        #expect(!shown.isEmpty)
    }

    @Test("未超限或已展开时原样返回")
    func passthrough() {
        let file = diff(lines: 3749)
        let total = file.hunks.reduce(0) { $0 + $1.lines.count }
        #expect(DiffSoftLimit.visible(file.hunks, total: total, showAll: true).reduce(0) { $0 + $1.lines.count } == total)
        let small = diff(lines: 10)
        let smallTotal = small.hunks.reduce(0) { $0 + $1.lines.count }
        #expect(DiffSoftLimit.visible(small.hunks, total: smallTotal, showAll: false).reduce(0) { $0 + $1.lines.count } == smallTotal)
    }
}

@Suite("差异超长行截断")
struct DiffLongLineTests {
    @Test("超长行被截断并带说明,短行原样返回")
    func clipsLongLines() {
        let long = String(repeating: "x", count: 5_000)
        let shown = DiffSoftLimit.displayText(long)
        #expect(shown.utf16.count < 1_100)
        #expect(shown.hasPrefix(String(repeating: "x", count: 1_000)))
        #expect(DiffSoftLimit.displayText("short") == "short")
    }
}
