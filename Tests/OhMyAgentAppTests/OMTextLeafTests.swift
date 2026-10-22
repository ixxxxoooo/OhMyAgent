// @author ixxxxoooo
// 文本叶子基础设施:内容签名去重、追加型更新只替换尾部、测量缓存、复制语义、单击回调。

import AppKit
import DesignSystem
import ChatKit
import DiffKit
import Foundation
import Testing

@testable import OhMyAgentApp

@MainActor
@Suite("文本叶子基础设施", .serialized)
struct OMTextLeafTests {
    /// 造一个纯文本富文本(统一属性,便于比较)。
    private func plain(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)])
    }

    @Test("签名不变时不改动文本存储")
    func sameSignatureIsNoOp() {
        let host = OMLeafHostView(wrap: true)
        let coordinator = OMTextLeafCoordinator()
        coordinator.apply(to: host.textView, signature: 1) { plain("你好") }
        let before = coordinator.edits
        var built = false
        coordinator.apply(to: host.textView, signature: 1) { built = true; return plain("你好") }
        #expect(coordinator.edits == before)
        #expect(!built, "签名没变时不应构建富文本")
    }

    @Test("长文本追加:只替换尾部,结果与整段重建一致")
    func appendReplacesOnlyTheTail() {
        let host = OMLeafHostView(wrap: true)
        let coordinator = OMTextLeafCoordinator()
        var text = String(repeating: "let value = compute(1)\n", count: 200)
        coordinator.apply(to: host.textView, signature: 1) { plain(text) }
        #expect(coordinator.fullRebuilds == 1)
        for step in 2...6 {
            text += "let extra\(step) = 1\n"
            coordinator.apply(to: host.textView, signature: step) { plain(text) }
            guard let storage = host.textView.textStorage else { Issue.record("没有文本存储"); return }
            #expect(storage.isEqual(to: NSTextStorage(attributedString: plain(text))))
        }
        #expect(coordinator.incrementalUpdates == 5)
        #expect(coordinator.fullRebuilds == 1)
    }

    @Test("非追加改写走整体重建")
    func rewriteFallsBackToFullRebuild() {
        let host = OMLeafHostView(wrap: true)
        let coordinator = OMTextLeafCoordinator()
        let base = String(repeating: "abc\n", count: 800)
        coordinator.apply(to: host.textView, signature: 1) { plain(base) }
        coordinator.apply(to: host.textView, signature: 2) { plain("X" + base.dropFirst() + "tail") }
        #expect(coordinator.fullRebuilds == 2)
        #expect(host.textView.string == "X" + base.dropFirst() + "tail")
    }

    @Test("同一宽度与内容的测量只做一次,宽度变化才重新测量")
    func measurementIsCached() {
        let host = OMLeafHostView(wrap: true)
        let coordinator = OMTextLeafCoordinator()
        let config = OMTextLeafConfig()
        coordinator.apply(to: host.textView, signature: 1) { plain(String(repeating: "很长的一行文字 ", count: 40)) }
        let narrow = coordinator.measuredSize(host, config: config, proposedWidth: 200)
        _ = coordinator.measuredSize(host, config: config, proposedWidth: 200)
        #expect(coordinator.measurePasses == 1)
        let wide = coordinator.measuredSize(host, config: config, proposedWidth: 800)
        #expect(coordinator.measurePasses == 2)
        #expect(wide.height < narrow.height, "更宽时折行更少,高度应更小")
    }

    @Test("不折行时内容宽度由最长行决定,宿主宽度等于建议宽度")
    func noWrapUsesLongestLine() {
        let host = OMLeafHostView(wrap: false)
        let coordinator = OMTextLeafCoordinator()
        var config = OMTextLeafConfig()
        config.wrap = false
        coordinator.apply(to: host.textView, signature: 1) { plain(String(repeating: "x", count: 500)) }
        let size = coordinator.measuredSize(host, config: config, proposedWidth: 300)
        #expect(size.width == 300)
        #expect(host.contentSize.width > 300)
        #expect(host.scrollView != nil)
    }

    @Test("复制变换作用于选中文本")
    func copyTransformApplies() {
        let host = OMLeafHostView(wrap: true)
        host.textView.textStorage?.setAttributedString(plain("甲\u{2028}乙"))
        host.textView.copyTransform = { $0.replacingOccurrences(of: "\u{2028}", with: "\n") }
        host.textView.setSelectedRange(NSRange(location: 0, length: 3))
        host.textView.copy(nil)
        #expect(NSPasteboard.general.string(forType: .string) == "甲\n乙")
    }

    @Test("叶子创建后只读、可选,背景透明")
    func leafIsReadOnlySelectable() {
        let view = OMReadOnlyTextView.make(OMReadOnlyTextView.self, layout: OMLeafLayoutManager())
        #expect(!view.isEditable)
        #expect(view.isSelectable)
        #expect(!view.drawsBackground)
        #expect(view.retainedStorage != nil)
    }
}

@MainActor
@Suite("Diff 文本叶子内容", .serialized)
struct OMDiffLeafContentTests {
    /// 由真实差异计算得到的行(上下文、删除、新增),末尾补一个并排视图里的空占位。
    private var lines: [DiffLine?] {
        let diff = LineDiff.diff(old: "let a = 1\nlet b = 2\n", new: "let a = 1\nlet b = 3\n")
        return (diff.hunks.first?.lines ?? []).map { Optional($0) } + [nil]
    }

    @Test("正文只含代码文本:行号、符号只存在于属性里,复制不会带上")
    func bodyIsPlainContent() {
        let text = OMLeafContent.diff(lines, marks: [nil, nil, 8..<9, nil], twoColumns: true)
        #expect(text.string == "let a = 1\nlet b = 2\nlet b = 3\n ")
    }

    @Test("每行都带底色与行号槽属性,行内变化区间带背景色")
    func attributesPresent() {
        let text = OMLeafContent.diff(lines, marks: [nil, nil, 8..<9, nil], twoColumns: true)
        var index = 0
        for line in text.string.split(separator: "\n", omittingEmptySubsequences: false) {
            #expect(text.attribute(omLineFillKey, at: index, effectiveRange: nil) != nil)
            #expect(text.attribute(omGutterKey, at: index, effectiveRange: nil) != nil)
            index += line.count + 1
        }
        // 第三行 "let b = 3" 的最后一个字符 "3" 有行内高亮背景
        let thirdStart = "let a = 1\nlet b = 2\n".count
        #expect(text.attribute(.backgroundColor, at: thirdStart + 8, effectiveRange: nil) != nil)
        #expect(text.attribute(.backgroundColor, at: thirdStart, effectiveRange: nil) == nil)
    }

    @Test("并排单侧:不画新旧两列,占位行保持一行高度")
    func sideBySideSingleColumn() {
        let old = OMLeafContent.diff(lines, marks: [], twoColumns: false, side: .old)
        let new = OMLeafContent.diff(lines, marks: [], twoColumns: false, side: .new)
        #expect(old.string.split(separator: "\n", omittingEmptySubsequences: false).count == 4)
        #expect(new.string.split(separator: "\n", omittingEmptySubsequences: false).count == 4)
    }
}

@MainActor
@Suite("文本叶子测量回退", .serialized)
struct OMTextLeafMeasureFallbackTests {
    @Test("没有任何宽度信息时按默认宽度排版,不产生虚高高度")
    func unknownWidthDoesNotInflateHeight() {
        let host = OMLeafHostView(wrap: true)
        let coordinator = OMTextLeafCoordinator()
        coordinator.apply(to: host.textView, signature: 1) {
            NSAttributedString(string: String(repeating: "一行普通的文字 ", count: 20),
                               attributes: [.font: NSFont.systemFont(ofSize: 13)])
        }
        let size = coordinator.measuredSize(host, config: OMTextLeafConfig(), proposedWidth: nil)
        #expect(size.height < 200, "实际高度 \(size.height) 说明按极窄宽度排版了")
        #expect(size.width > 100)
    }
}

@MainActor
@Suite("表格文本叶子内容", .serialized)
struct OMTableLeafContentTests {
    /// 复制整段内容(与选区复制同一条路径)。
    private func copied(_ text: NSAttributedString) -> String {
        OMReadOnlyTextView.copyText(of: text, range: NSRange(location: 0, length: text.length), transform: nil)
    }

    @Test("复制得到 TSV:单元格以制表符分隔、行以换行分隔(行内 Markdown 标记已去掉)")
    func tsvText() {
        let text = OMLeafContent.table(header: ["模块", "说明"], rows: [["**核心**", "`ACPKit`"], ["界面", "SwiftUI"]])
        #expect(copied(text) == "模块\t说明\n核心\tACPKit\n界面\tSwiftUI")
    }

    @Test("每个单元格是一个 NSTextTable 单元,表头与各行共用同一张表")
    func sharesOneTable() {
        let text = OMLeafContent.table(header: ["甲", "乙"], rows: [["1", "2"], ["3", "4"]])
        var tables = Set<ObjectIdentifier>()
        var cells = 0
        text.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            guard let style = value as? NSParagraphStyle, let block = style.textBlocks.first as? NSTextTableBlock else { return }
            tables.insert(ObjectIdentifier(block.table))
            cells += 1
        }
        #expect(tables.count == 1)
        #expect(cells >= 6, "3 行 × 2 列至少 6 个单元(属性段合并时可能少于段落数,但不应少于行数×列数的一半)")
    }

    @Test("列宽取整列最宽单元格并夹在 [最小, 最大] 之间;表头与行使用同一列宽")
    func columnMetrics() {
        let metrics = OMLeafContent.tableMetrics(naturalWidths: [10, 120, 900], horizontalPadding: 10)
        #expect(metrics.columnWidths[0] == OMLeafContent.tableMinColumn)
        #expect(metrics.columnWidths[1] == 122)
        #expect(metrics.columnWidths[2] == OMLeafContent.tableMaxColumn)
        #expect(metrics.totalWidth == metrics.columnWidths.reduce(0, +) + 60)
    }

    @Test("给定可用宽度时按注水分配:短列保持原宽,长列平分剩余并折行,整表不超过可用宽度")
    func fitsAvailableWidth() {
        let metrics = OMLeafContent.tableMetrics(naturalWidths: [30, 600, 600], horizontalPadding: 10, maxTotalWidth: 500)
        #expect(metrics.columnWidths[0] == OMLeafContent.tableMinColumn)
        #expect(metrics.columnWidths[1] == metrics.columnWidths[2])
        #expect(metrics.totalWidth <= 500)
        // 宽度足够时保持自然宽度(且不受单列 360 上限限制)
        let roomy = OMLeafContent.tableMetrics(naturalWidths: [30, 600], horizontalPadding: 10, maxTotalWidth: 2000)
        #expect(roomy.columnWidths == [OMLeafContent.tableMinColumn, 602])
        // 空间小到每列最小宽度都放不下时,退回最小宽度(此时才横向滚动)
        let tiny = OMLeafContent.tableMetrics(naturalWidths: [300, 300], horizontalPadding: 10, maxTotalWidth: 50)
        #expect(tiny.columnWidths == [OMLeafContent.tableMinColumn, OMLeafContent.tableMinColumn])
    }

    @Test("行不足的数据行按空单元格补齐;空表返回空文本")
    func raggedAndEmpty() {
        let text = OMLeafContent.table(header: ["a", "b"], rows: [["1"]])
        #expect(copied(text) == "a\tb\n1\t")
        #expect(OMLeafContent.table(header: [], rows: []).length == 0)
    }

    @Test("对齐语法映射到段落对齐")
    func alignments() {
        let text = OMLeafContent.table(header: ["l", "c", "r"], rows: [["1", "2", "3"]], aligns: [.left, .center, .right])
        var found: [NSTextAlignment] = []
        text.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if let style = value as? NSParagraphStyle { found.append(style.alignment) }
        }
        #expect(found.contains(.center) && found.contains(.right) && found.contains(.left))
    }

    @Test("宽表排版后宽度约等于列宽之和(不被撑到 1e6 容器宽度),超宽单元格在单元格内折行")
    func layoutWidth() {
        let host = OMLeafHostView(wrap: false)
        let long = String(repeating: "很长的单元格内容 ", count: 40)
        let text = OMLeafContent.table(header: ["编号", "说明"], rows: [["1", long], ["2", "短"]])
        host.textView.textStorage?.setAttributedString(text)
        let size = host.textView.layoutSize(containerWidth: 1_000_000)
        let maxTotal = OMLeafContent.tableMaxColumn + OMLeafContent.tableMinColumn + 40 + 80
        #expect(size.width > 200 && size.width <= maxTotal, "宽度 \(size.width)")
        #expect(size.height > 60, "长单元格应折成多行,高度 \(size.height)")
    }
}

@MainActor
@Suite("表格测量", .serialized)
struct OMTableMeasureTests {
    @Test("右对齐/居中列不会把测量宽度撑到容器宽度(以表格总宽为准)")
    func alignedColumnsKeepIntrinsicWidth() {
        let host = OMLeafHostView(wrap: false)
        host.textView.textStorage?.setAttributedString(OMLeafContent.table(header: ["Item", "Qty"], rows: [["Apple", "12"]], aligns: [.none, .right]))
        let size = host.textView.layoutSize(containerWidth: 1_000_000)
        #expect(size.width < 400, "宽度 \(size.width)")
    }

    @Test("hugsContent:内容比建议宽度窄时叶子宽度贴合表格,超宽时等于建议宽度")
    func hugsContent() {
        let coordinator = OMTextLeafCoordinator()
        let host = OMLeafHostView(wrap: false)
        coordinator.apply(to: host.textView, signature: 1) { OMLeafContent.table(header: ["a", "b"], rows: [["1", "2"]]) }
        let config = OMTextLeafConfig(wrap: false, inset: .zero, persistentScroller: true, hugsContent: true)
        let narrow = coordinator.measuredSize(host, config: config, proposedWidth: 800)
        #expect(narrow.width < 400, "宽度 \(narrow.width)")
        let tight = coordinator.measuredSize(host, config: config, proposedWidth: 100)
        #expect(tight.width == 100)
    }
}

@Suite("Markdown 表格解析")
struct MarkdownTableParseTests {
    @Test("分隔行解析列对齐")
    func aligns() {
        let blocks = MarkdownParser.parse("| a | b | c | d |\n| :--- | :---: | ---: | --- |\n| 1 | 2 | 3 | 4 |")
        guard case .table(_, _, let aligns) = blocks[0] else { Issue.record("应是表格"); return }
        #expect(aligns == [.left, .center, .right, .none])
    }

    @Test("转义竖线不分列")
    func escapedPipe() {
        let blocks = MarkdownParser.parse("| a | b |\n| --- | --- |\n| x \\| y | z |")
        guard case .table(_, let rows, _) = blocks[0] else { Issue.record("应是表格"); return }
        #expect(rows == [["x | y", "z"]])
    }
}
