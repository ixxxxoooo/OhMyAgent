// @author ixxxxoooo
// 编辑文档:批量编辑、撤销/重做、输入合并、脏状态、外部重载与观察者通知。

import Foundation
import Testing
@testable import EditorCore

/// 可手动推进的时钟。
@MainActor
final class FakeClock {
    var now: TimeInterval = 0
}

@MainActor
@Suite("编辑文档")
struct EditorDocumentTests {
    @Test("批量编辑按原坐标一次应用,顺序任意")
    func batchEdit() throws {
        let document = EditorDocument(text: "one two three")
        try document.apply([
            DocumentEdit(range: TextRange(location: 8, length: 5), text: "3"),
            DocumentEdit(range: TextRange(location: 0, length: 3), text: "1"),
            DocumentEdit(range: TextRange(location: 4, length: 3), text: "2"),
        ])
        #expect(document.text() == "1 2 3")
        #expect(document.version == 1)
    }

    @Test("越界与重叠的编辑被拒绝且文档不变")
    func rejectsInvalid() {
        let document = EditorDocument(text: "abc")
        #expect(throws: EditorDocumentError.rangeOutOfBounds(TextRange(location: 2, length: 5))) {
            try document.replace(TextRange(location: 2, length: 5), with: "x")
        }
        #expect(throws: EditorDocumentError.overlappingEdits) {
            try document.apply([
                DocumentEdit(range: TextRange(location: 0, length: 2), text: "x"),
                DocumentEdit(range: TextRange(location: 1, length: 2), text: "y"),
            ])
        }
        #expect(document.text() == "abc" && document.version == 0 && !document.isDirty)
    }

    @Test("撤销与重做还原文本与选区")
    func undoRedo() throws {
        let document = EditorDocument(text: "hello")
        try document.replace(TextRange(location: 5, length: 0), with: " world",
                             selectionsBefore: [Selection(caret: 5)], selectionsAfter: [Selection(caret: 11)])
        try document.replace(TextRange(location: 0, length: 5), with: "HELLO",
                             selectionsBefore: [Selection(anchor: 0, head: 5)], selectionsAfter: [Selection(caret: 5)])
        #expect(document.text() == "HELLO world")
        #expect(document.undo() == [Selection(anchor: 0, head: 5)])
        #expect(document.text() == "hello world")
        #expect(document.undo() == [Selection(caret: 5)])
        #expect(document.text() == "hello")
        #expect(document.undo() == nil)
        #expect(document.redo() == [Selection(caret: 11)])
        #expect(document.redo() == [Selection(caret: 5)])
        #expect(document.text() == "HELLO world")
        #expect(document.redo() == nil)
    }

    @Test("新编辑清空重做栈")
    func editClearsRedo() throws {
        let document = EditorDocument(text: "a")
        try document.replace(TextRange(location: 1, length: 0), with: "b")
        document.undo()
        #expect(document.canRedo)
        try document.replace(TextRange(location: 1, length: 0), with: "c")
        #expect(!document.canRedo)
        #expect(document.text() == "ac")
    }

    @Test("同键连续输入在窗口内合并,超时或换键则分开")
    func coalescing() throws {
        let clock = FakeClock()
        let document = EditorDocument(text: "", clock: { clock.now })
        for (index, character) in "abc".enumerated() {
            clock.now += 0.1
            try document.replace(TextRange(location: index, length: 0), with: String(character), coalesceKey: "typing")
        }
        #expect(document.text() == "abc")
        document.undo()
        #expect(document.text() == "" && !document.canUndo)
        document.redo()
        clock.now += 5
        try document.replace(TextRange(location: 3, length: 0), with: "d", coalesceKey: "typing")
        try document.replace(TextRange(location: 4, length: 0), with: "e", coalesceKey: "other")
        document.undo()
        #expect(document.text() == "abcd")
        document.undo()
        #expect(document.text() == "abc")
    }

    @Test("脏状态:保存后撤销再重做回到已保存点即为干净")
    func dirtyTracking() throws {
        let document = EditorDocument(text: "x")
        #expect(!document.isDirty)
        try document.replace(TextRange(location: 1, length: 0), with: "y")
        #expect(document.isDirty)
        document.markSaved()
        #expect(!document.isDirty)
        document.undo()
        #expect(document.isDirty)
        document.redo()
        #expect(!document.isDirty)
    }

    @Test("观察者收到按应用顺序的编辑,撤销时收到逆编辑")
    func observers() throws {
        let document = EditorDocument(text: "abcdef")
        var received: [DocumentChange] = []
        let token = document.addObserver { received.append($0) }
        try document.apply([
            DocumentEdit(range: TextRange(location: 0, length: 1), text: "XX"),
            DocumentEdit(range: TextRange(location: 4, length: 2), text: ""),
        ])
        document.undo()
        document.removeObserver(token)
        try document.replace(TextRange(location: 0, length: 0), with: "z")
        #expect(received.count == 2)
        #expect(received[0].edits == [AppliedEdit(location: 4, oldLength: 2, newLength: 0),
                                      AppliedEdit(location: 0, oldLength: 1, newLength: 2)])
        #expect(received[1].origin == .undo)
        #expect(received[1].edits == [AppliedEdit(location: 0, oldLength: 2, newLength: 1),
                                      AppliedEdit(location: 4, oldLength: 0, newLength: 2)])
        #expect(received[1].snapshot.string() == "abcdef")
        #expect(received[1].version == 2)
    }

    @Test("CRLF 文件装载归一,保存时还原")
    func lineEndingRoundTrip() throws {
        let document = EditorDocument(text: "a\r\nb\r\n")
        #expect(document.text() == "a\nb\n" && document.lineEnding == .crlf)
        try document.replace(TextRange(location: 0, length: 0), with: "x\r\ny")
        #expect(document.text() == "x\nya\nb\n")
        #expect(document.textForSaving() == "x\r\nya\r\nb\r\n")
    }

    @Test("外部重载只替换差异区间,保留撤销并视为已保存")
    func externalReload() throws {
        let document = EditorDocument(text: "line1\nline2\nline3\n")
        var changes: [DocumentChange] = []
        document.addObserver { changes.append($0) }
        let change = document.applyExternal(text: "line1\nLINE2\nline3\n")
        #expect(document.text() == "line1\nLINE2\nline3\n")
        #expect(change?.edits == [AppliedEdit(location: 6, oldLength: 4, newLength: 4)])
        #expect(change?.origin == .external && !document.isDirty)
        #expect(document.applyExternal(text: "line1\nLINE2\nline3\n") == nil)
        document.undo()
        #expect(document.text() == "line1\nline2\nline3\n" && document.isDirty)
        #expect(changes.count == 2)
    }

    @Test("注册表按标准化路径共享文档,弱引用释放后重建")
    func registry() {
        let registry = EditorDocumentRegistry()
        var loads = 0
        var first: EditorDocument? = registry.document(forPath: "/tmp/a/../a/file.swift") { loads += 1; return "x" }
        let second = registry.document(forPath: "/tmp/a/file.swift") { loads += 1; return "y" }
        #expect(first === second && loads == 1)
        first = nil
        #expect(registry.existingDocument(forPath: "/tmp/a/file.swift") != nil)
        _ = second
    }
}
