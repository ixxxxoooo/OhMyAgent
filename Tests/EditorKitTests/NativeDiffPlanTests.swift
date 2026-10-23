// @author ixxxxoooo
// 原生 Diff 方案:块划分、字符级配对、对齐占位与折叠区域的单元测试。

import AppKit
import DiffKit
import EditorCore
import Foundation
import Testing
@testable import EditorKit

@Suite("NativeDiffPlan")
struct NativeDiffPlanTests {
    private func lines(_ count: Int, prefix: String = "行") -> [String] { (0..<count).map { "\(prefix)\($0)" } }

    @Test("替换块:两侧行数、字符级配对")
    func replaceBlock() {
        var old = lines(10), new = lines(10)
        old[4] = "let value = 1"
        new[4] = "let value = 22"
        let diff = LineDiff.diff(old: old.joined(separator: "\n"), new: new.joined(separator: "\n"))
        let plan = NativeDiffPlan.make(from: diff)
        #expect(plan.blocks.count == 1)
        let block = plan.blocks[0]
        #expect(block.oldStart == 4 && block.oldCount == 1 && block.newStart == 4 && block.newCount == 1)
        #expect(block.hunkID != nil)
        #expect(block.pairs.count == 1)
        #expect(NativeDiffPlan.padding(for: block, oldSide: true) == 0)
        #expect(NativeDiffPlan.padding(for: block, oldSide: false) == 0)
    }

    @Test("纯新增:旧侧补占位,锚点位置正确")
    func pureInsert() {
        let old = lines(6)
        var new = old
        new.insert(contentsOf: ["新增1", "新增2"], at: 3)
        let diff = LineDiff.diff(old: old.joined(separator: "\n"), new: new.joined(separator: "\n"))
        let plan = NativeDiffPlan.make(from: diff)
        #expect(plan.blocks.count == 1)
        let block = plan.blocks[0]
        #expect(block.oldCount == 0 && block.newCount == 2)
        #expect(block.oldStart == 3 && block.newStart == 3)
        #expect(NativeDiffPlan.padding(for: block, oldSide: true) == 2)
        #expect(NativeDiffPlan.padding(for: block, oldSide: false) == 0)
    }

    @Test("纯删除:新侧补占位")
    func pureDelete() {
        let old = lines(8)
        var new = old
        new.removeSubrange(2..<5)
        let diff = LineDiff.diff(old: old.joined(separator: "\n"), new: new.joined(separator: "\n"))
        let block = NativeDiffPlan.make(from: diff).blocks[0]
        #expect(block.oldCount == 3 && block.newCount == 0)
        #expect(block.oldStart == 2 && block.newStart == 2)
        #expect(NativeDiffPlan.padding(for: block, oldSide: false) == 3)
    }

    @Test("折叠区:两侧隐藏行数一致,起始行保持可见")
    func foldsAreSymmetric() {
        var old = lines(60), new = lines(60)
        new[30] = "改动"
        new.insert("多出一行", at: 31)
        old[2] = "头部改动"
        new[2] = "头部改动!"
        let diff = LineDiff.diff(old: old.joined(separator: "\n"), new: new.joined(separator: "\n"))
        let plan = NativeDiffPlan.make(from: diff)
        #expect(plan.blocks.count == 2)
        #expect(plan.folds.count >= 2)
        for fold in plan.folds {
            #expect(fold.old.endLine - fold.old.startLine == fold.new.endLine - fold.new.startLine)
            #expect(fold.old.endLine - fold.old.startLine >= 3)
        }
        // 第一块之后留 3 行上下文,折叠从其后一行开始隐藏。
        let first = plan.folds[0]
        #expect(first.new.startLine == plan.blocks[0].newStart + plan.blocks[0].newCount + 3 - 1)
        // 折叠区域不覆盖改动行。
        for fold in plan.folds {
            for block in plan.blocks {
                let hiddenNew = (fold.new.startLine + 1)...fold.new.endLine
                #expect(!hiddenNew.overlaps(block.newStart..<(block.newStart + max(block.newCount, 1))) || block.newCount == 0 && !hiddenNew.contains(block.newStart - 1))
            }
        }
    }

    @Test("无差异:空方案")
    func noDiff() {
        let diff = LineDiff.diff(old: "a\nb\nc", new: "a\nb\nc")
        let plan = NativeDiffPlan.make(from: diff)
        #expect(plan.blocks.isEmpty)
        #expect(plan.folds.isEmpty)
    }

    @Test("Character 偏移换算为 UTF-16 偏移")
    @MainActor
    func utf16Offsets() {
        #expect(NativeDiffView.utf16Offset(of: 0, in: "abc") == 0)
        #expect(NativeDiffView.utf16Offset(of: 2, in: "a😀b") == 3)
        #expect(NativeDiffView.utf16Offset(of: 99, in: "ab") == 2)
    }

    @Test("并排视图:对齐占位使两侧总高度一致,并支持折叠镜像")
    @MainActor
    func sideBySideAlignment() {
        var old = lines(40), new = lines(40)
        new.insert(contentsOf: ["a", "b", "c"], at: 10)
        old[25] = "旧"
        new[28] = "新"
        let oldText = old.joined(separator: "\n"), newText = new.joined(separator: "\n")
        let diff = LineDiff.diff(old: oldText, new: newText)
        let view = NativeDiffView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        view.show(old: oldText, new: newText, diff: diff, mode: .sideBySide, language: .plain, fileName: nil, actions: [])
        view.layoutSubtreeIfNeeded()
        guard let left = view.oldEditor, let right = view.newEditor else { Issue.record("缺少编辑器"); return }
        // 折叠后两侧可见行数 + zone 高度总和应相同(对齐)。
        let leftHeight = left.model.zoneLayout.totalZoneHeight + Double(left.model.lineMap.totalRows) * left.model.lineHeight
        let rightHeight = right.model.zoneLayout.totalZoneHeight + Double(right.model.lineMap.totalRows) * right.model.lineHeight
        #expect(abs(leftHeight - rightHeight) < 0.5)
        // 折叠镜像:展开左侧后右侧同步展开。
        let fold = view.plan.folds[0]
        left.model.unfold(line: fold.old.startLine)
        #expect(!right.model.folds.isCollapsed(startLine: fold.new.startLine))
        left.model.fold(line: fold.old.startLine)
        #expect(right.model.folds.isCollapsed(startLine: fold.new.startLine))
    }
}
