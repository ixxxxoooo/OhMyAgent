// @author ixxxxoooo
// 原生编辑器的折叠命令与区域刷新:折叠/展开/全部、按层级、折叠其它;缩进+块头推断的区域在后台计算。

import AppKit
import EditorCore

extension NativeEditorModel {
    // MARK: 区域刷新

    /// 在后台重新推断可折叠区域(缩进 + 块头),完成后回写;过期结果丢弃。
    /// - Parameter delay: 防抖延迟,0 表示立即开始
    public func refreshFoldRegions(after delay: Duration = .zero) {
        foldGeneration += 1
        let token = foldGeneration
        foldTask?.cancel()
        let rope = document.snapshot
        foldTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            let regions = await Task.detached(priority: .utility) {
                EditorFolding.allRegions(lineCount: rope.lineCount, text: { rope.lineText($0) })
                    .map { EditorCore.FoldRegion(startLine: $0.header, endLine: $0.body.upperBound) }
            }.value
            guard !Task.isCancelled, let self, token == self.foldGeneration else { return }
            self.setFoldRegions(regions)
        }
    }

    // MARK: 命令

    /// 折叠/展开 `line` 所在区域。
    public func toggleFold(line: Int) {
        guard folds.toggle(line: line) else { return }
        applyFolds()
    }

    /// 折叠包含 `line` 的最内层未折叠区域(光标在被折叠区域内时移到块头)。
    public func fold(line: Int) {
        guard folds.fold(line: line) else { return }
        applyFolds()
    }

    /// 展开包含 `line` 的折叠区域。
    public func unfold(line: Int) {
        guard folds.unfold(line: line) else { return }
        applyFolds()
    }

    /// 折叠全部。
    public func foldAll() {
        folds.foldAll()
        applyFolds()
    }

    /// 展开全部。
    public func unfoldAll() {
        folds.unfoldAll()
        applyFolds()
    }

    /// 折叠到某层级(从 1 起)。
    public func foldLevel(_ level: Int) {
        folds.fold(level: max(level, 1))
        applyFolds()
    }

    /// 折叠除光标所在区域之外的全部区域。
    public func foldAllExceptSelection() {
        let rope = document.snapshot
        folds.foldAllExcept(lines: selections.selections.map { rope.line(containing: $0.head) })
        applyFolds()
    }

    /// 选区若落在被隐藏的行里,展开所属折叠(跳转/查找命中时自动揭示)。
    func revealHiddenSelection() {
        guard !folds.collapsedStarts.isEmpty else { return }
        let rope = document.snapshot
        var changed = false
        for selection in selections.selections {
            let line = rope.line(containing: selection.head)
            while folds.isHidden(line: line), folds.unfold(line: line) { changed = true }
        }
        if changed { applyFolds() }
    }
}
