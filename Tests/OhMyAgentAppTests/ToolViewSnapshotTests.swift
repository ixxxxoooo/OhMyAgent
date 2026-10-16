// @author ixxxxoooo
// 工具视图渲染测试:用 NSHostingView 把工具行/分组渲染为位图,浅色与深色各一份。
// 断言:能渲染出非空内容、尺寸合理、浅深色确有差异;设置 OMA_SNAPSHOT_DIR 时同时导出 PNG 供人工核对。

import ACPKit
import AppKit
import ChatKit
import SwiftUI
import Testing

@testable import OhMyAgentApp

private let toolCases: [(String, ToolCall)] = [
    ("read", ToolCall(toolCallId: "r", name: "Read", title: "读取", kind: .read, status: .completed, rawInput: ["file_path": "/p/Sources/main.swift", "offset": 10, "limit": 40])),
    ("write", ToolCall(toolCallId: "w", name: "Write", kind: .edit, status: .completed, content: [.diff(path: "/p/NOTES.md", oldText: nil, newText: "# 标题\n\n内容\n")], rawInput: ["file_path": "/p/NOTES.md"])),
    ("edit", ToolCall(toolCallId: "e", name: "Edit", kind: .edit, status: .completed, content: [.diff(path: "/p/a.swift", oldText: "a\nb\n", newText: "a\nB\nc\n")], rawInput: ["file_path": "/p/a.swift"])),
    ("search", ToolCall(toolCallId: "s", name: "Grep", kind: .search, status: .completed, content: [.content(.text("/p/a.swift:3: // TODO x\n/p/b.swift:9: // TODO y"))], rawInput: ["pattern": "TODO"])),
    ("bash", ToolCall(toolCallId: "b", name: "Bash", kind: .execute, status: .completed, content: [.content(.text("\u{1B}[32mok\u{1B}[0m\n\u{1B}[31mfail\u{1B}[0m"))], rawInput: ["command": "swift test"])),
    ("mcp", ToolCall(toolCallId: "m", name: "mcp__github__create_issue", kind: .other, status: .completed, content: [.content(.text("{\"n\":1}"))], rawInput: ["title": "t"])),
    ("fail", ToolCall(toolCallId: "f", name: "Bash", kind: .execute, status: .failed, content: [.content(.text("boom"))], rawInput: ["command": "false"])),
    ("running", ToolCall(toolCallId: "g", name: "Read", kind: .read, status: .inProgress, rawInput: ["file_path": "/p/x.swift"])),
]


@MainActor
@Suite("工具视图渲染")
struct ToolViewSnapshotTests {
    private func entry(_ tool: ToolCall) -> TimelineEntry {
        let store = TimelineStore()
        store.apply(.toolCall(tool))
        return store.entries[0]
    }

    /// 渲染视图为位图。
    private func render<V: View>(_ view: V, dark: Bool, width: CGFloat = 640) -> NSBitmapImageRep? {
        let model = SessionModel(workspace: URL(fileURLWithPath: NSTemporaryDirectory()))
        let host = NSHostingView(rootView: view.environment(model).frame(width: width).padding(8).background(Color(nsColor: .textBackgroundColor)))
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        guard size.width > 0, size.height > 0, let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    /// 位图中不同颜色像素的占比(粗略判断“不是空白”)。
    private func inkRatio(_ rep: NSBitmapImageRep) -> Double {
        guard let base = rep.colorAt(x: 0, y: 0) else { return 0 }
        var different = 0, total = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                total += 1
                if let color = rep.colorAt(x: x, y: y), abs(color.redComponent - base.redComponent) + abs(color.greenComponent - base.greenComponent) + abs(color.blueComponent - base.blueComponent) > 0.08 { different += 1 }
            }
        }
        return total == 0 ? 0 : Double(different) / Double(total)
    }

    private func export(_ rep: NSBitmapImageRep, name: String) {
        guard let dir = ProcessInfo.processInfo.environment["OMA_SNAPSHOT_DIR"], let data = rep.representation(using: .png, properties: [:]) else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }

    @Test("每种工具在浅色与深色下都能渲染出内容", arguments: toolCases.map(\.0))
    func rendersAll(name: String) throws {
        let tool = try #require(toolCases.first { $0.0 == name }?.1)
        let item = entry(tool)
        let light = try #require(render(ToolRowView(entry: item), dark: false))
        let dark = try #require(render(ToolRowView(entry: item), dark: true))
        #expect(light.pixelsHigh >= 20, "行高过小:\(name)")
        #expect(light.pixelsHigh < 2400)
        #expect(inkRatio(light) > 0.004, "浅色渲染为空白:\(name)")
        #expect(inkRatio(dark) > 0.004, "深色渲染为空白:\(name)")
        export(light, name: "tool-\(name)-light")
        export(dark, name: "tool-\(name)-dark")
    }

    @Test("工具行默认一律折叠:带 Diff 的编辑与普通读取行同高")
    func toolRowsCollapsedByDefault() throws {
        let edit = entry(toolCases[2].1)
        let read = entry(toolCases[0].1)
        let editImage = try #require(render(ToolRowView(entry: edit), dark: false))
        let readImage = try #require(render(ToolRowView(entry: read), dark: false))
        #expect(abs(editImage.pixelsHigh - readImage.pixelsHigh) <= 8, "编辑行不应默认展开 Diff 详情")
    }

    @Test("ANSI 富文本包含颜色属性且文本被还原")
    func ansiAttributed() {
        let text = ANSITextView.attributed("a\u{1B}[31mb\u{1B}[0mc", fontSize: 12)
        #expect(String(text.characters) == "abc")
        let colored = text.runs.filter { $0.foregroundColor != nil }
        #expect(colored.count == 1)
    }

    @Test("耗时格式")
    func durationFormat() {
        #expect(ToolRowView.format(0.04) == "0.0 秒")
        #expect(ToolRowView.format(3.26) == "3.3 秒")
        #expect(ToolRowView.format(42) == "42 秒")
        #expect(ToolRowView.format(125) == "2 分 5 秒")
    }
}
