// @author ixxxxoooo
// IDE 窗口的语言服务扩展命令:查找引用、转到符号、重命名符号、格式化文档,以及大纲(OUTLINE)数据。
// 语言服务器会话由 `FileTabView` 登记到工作区(`registerLSP`),这里按活动文件取用。

import AppKit
import EditorKit
import Foundation
import LSPKit
import OMLog

extension IDEWorkspace {
    /// 登记或注销某文件的语言服务器会话。
    /// - Parameters:
    ///   - controller: 会话;nil 为注销
    ///   - path: 文件路径
    func registerLSP(_ controller: EditorLSPController?, for path: String) {
        if let controller { lspControllers[path] = controller } else { lspControllers[path] = nil }
        if path == model.activeFilePath { refreshOutline() }
    }

    /// 活动文件的语言服务器会话(未就绪为 nil)。
    var activeLSP: EditorLSPController? {
        guard let path = model.activeFilePath, let controller = lspControllers[path], controller.isReady else { return nil }
        return controller
    }

    /// 活动文件光标处的 UTF-16 偏移。
    private func caretOffset(in controller: EditorLSPController, path: String) -> Int {
        guard let caret = carets[path] else { return 0 }
        return LSPTextMapping.offset(of: LSPPosition(line: caret.line - 1, character: caret.column - 1), in: LineIndex(text: controller.text))
    }

    /// 没有可用语言服务器时的提示。
    private func reportUnavailable() {
        OMDialog.alert(title: String(localized: "语言服务不可用"), message: String(localized: "当前文件没有就绪的语言服务器(未安装、已关闭或仍在启动)。"), isError: false)
    }

    // MARK: 大纲

    /// 刷新大纲(活动文件切换、服务器就绪、保存后调用)。
    func refreshOutline() {
        outlineTask?.cancel()
        guard let path = model.activeFilePath, let controller = lspControllers[path], controller.isReady else {
            // 语言服务器尚未就绪:先保留旧大纲避免切换时闪空,稍后仍无结果再清空
            let stale = model.activeFilePath
            outlineTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(800))
                guard !Task.isCancelled, let self, self.model.activeFilePath == stale, self.outlinePath != stale else { return }
                self.outline = []
                self.outlinePath = nil
            }
            return
        }
        outlineTask = Task { [weak self] in
            let symbols = await controller.symbols()
            guard !Task.isCancelled, let self, self.model.activeFilePath == path else { return }
            self.outline = symbols
            self.outlinePath = path
        }
    }

    // MARK: 命令

    /// 转到符号(⇧⌘O):以列表形式列出当前文件的符号,可过滤。
    func showSymbols() {
        guard let path = model.activeFilePath, let controller = activeLSP else { reportUnavailable(); return }
        Task {
            let symbols = await controller.symbols()
            let items = symbols.flatMap { $0.flattened() }.map { entry in
                IDEPaletteLocation(id: "\(entry.symbol.id)", title: entry.symbol.name, detail: entry.symbol.detail ?? "",
                                   icon: entry.symbol.kind.iconName, path: path, line: entry.symbol.line + 1, depth: entry.depth)
            }
            palette.present(custom: items, placeholder: String(localized: "转到符号"))
        }
    }

    /// 查找引用(⇧F12):列出光标处符号的全部引用。
    func showReferences() {
        guard let path = model.activeFilePath, let controller = activeLSP else { reportUnavailable(); return }
        let offset = caretOffset(in: controller, path: path)
        Task {
            // 索引异步建立:查引用包含声明,空结果必然是索引未就绪 → 面板里提示「索引中」并自动重试
            var locations = await controller.references(at: offset)
            var attempt = 0
            while locations.isEmpty, attempt < NativeLanguageController.referenceRetries {
                if attempt == 0 {
                    palette.present(custom: [], placeholder: String(localized: "引用"), emptyMessage: String(localized: "语言服务正在建立索引,稍后自动重试…"))
                }
                try? await Task.sleep(for: NativeLanguageController.referenceRetryInterval)
                guard palette.isPresented else { return }   // 用户已关掉面板:不再重试,也不弹出结果
                attempt += 1
                locations = await controller.references(at: offset)
            }
            let root = self.root ?? ""
            var cache: [String: [String]] = [:]
            let items = locations.compactMap { location -> IDEPaletteLocation? in
                guard let target = LSPURI.path(from: location.uri) else { return nil }
                let lines: [String]
                if let cached = cache[target] { lines = cached } else {
                    lines = ((try? String(contentsOfFile: target, encoding: .utf8)) ?? "").components(separatedBy: "\n")
                    cache[target] = lines
                }
                let line = location.range.start.line
                let preview = lines.indices.contains(line) ? lines[line].trimmingCharacters(in: .whitespaces) : ""
                let relative = target.hasPrefix(root + "/") ? String(target.dropFirst(root.count + 1)) : target
                return IDEPaletteLocation(id: "\(target):\(line):\(location.range.start.character)", title: preview.isEmpty ? relative : preview,
                                          detail: "\(relative):\(line + 1)", icon: "file-code", path: target, line: line + 1)
            }
            if items.isEmpty {
                palette.dismiss()
                OMDialog.alert(title: String(localized: "没有找到引用"), message: "", isError: false)
                return
            }
            palette.present(custom: items, placeholder: String(localized: "引用(\(items.count))"))
        }
    }

    /// 重命名符号(F2):输入新名称后,把服务器给出的编辑应用到相关文件。
    func renameSymbol() {
        guard let path = model.activeFilePath, let controller = activeLSP else { reportUnavailable(); return }
        guard let name = OMDialog.prompt(title: String(localized: "重命名符号"), validate: { $0.isEmpty || $0.contains(where: \.isWhitespace) ? String(localized: "名称不能为空或包含空白") : nil }),
              !name.isEmpty else { return }
        let offset = caretOffset(in: controller, path: path)
        Task {
            guard let edit = await controller.rename(at: offset, to: name), edit.editCount > 0 else {
                OMDialog.alert(title: String(localized: "无法重命名"), message: String(localized: "语言服务器没有返回修改。"), isError: false)
                return
            }
            let files = await applyWorkspaceEdit(edit)
            Log.lsp.info("IDE 重命名", ["files": "\(files)", "edits": "\(edit.editCount)"])
        }
    }

    /// 快速修复(⌘.):向语言服务器请求光标/选区处的代码操作,以列表形式让用户选择并应用其编辑。
    func showCodeActions() {
        guard let path = model.activeFilePath, let controller = activeLSP else { reportUnavailable(); return }
        let start = caretOffset(in: controller, path: path)
        let range = NSRange(location: start, length: carets[path]?.selectedLength ?? 0)
        Task { [weak self] in
            guard let self else { return }
            let actions = await controller.codeActions(in: range)
            guard !actions.isEmpty else {
                OMDialog.alert(title: String(localized: "没有可用的快速修复"), message: "", isError: false)
                return
            }
            paletteActions = [:]
            let sorted = actions.sorted { $0.isPreferred && !$1.isPreferred }
            let items = sorted.enumerated().map { index, action -> IDEPaletteLocation in
                let id = "codeAction:\(index)"
                paletteActions[id] = { [weak self] in
                    let resolved = await controller.resolve(action)
                    guard let edit = resolved.edit, edit.editCount > 0, let self else { return }
                    let files = await self.applyWorkspaceEdit(edit)
                    Log.lsp.info("IDE 快速修复", ["title": action.title, "files": "\(files)", "edits": "\(edit.editCount)"])
                }
                var item = IDEPaletteLocation(id: id, title: action.title, detail: action.kind ?? "", icon: "wrench", path: path, line: 0)
                item.actionID = id
                return item
            }
            palette.present(custom: items, placeholder: String(localized: "快速修复"))
        }
    }

    /// 格式化当前文档(⇧⌥F):应用服务器给出的整篇编辑到缓冲区(标记为未保存)。
    func formatDocument() {
        guard let path = model.activeFilePath, let controller = activeLSP else { reportUnavailable(); return }
        Task {
            let edits = await controller.formatEdits(tabSize: 4, insertSpaces: true)
            guard !edits.isEmpty else { return }
            let document = FileDocumentStore.shared.document(for: path)
            guard let text = document.text else { return }
            let formatted = LSPTextEdits.apply(edits, to: text)
            if formatted != text { document.text = formatted }
            syncDirtyFlags()
        }
    }

    /// 应用工作区编辑:已打开的文件改缓冲区(标记未保存,可撤回前先保存),其余文件直接读改写磁盘。
    /// - Parameter edit: 工作区编辑
    /// - Returns: 修改的文件数
    @discardableResult
    func applyWorkspaceEdit(_ edit: LSPWorkspaceEdit) async -> Int {
        var changed = 0
        for (uri, edits) in edit.changes {
            guard let path = LSPURI.path(from: uri) else { continue }
            if model.openFilePaths.contains(path) {
                let document = FileDocumentStore.shared.document(for: path)
                guard let text = document.text else { continue }
                document.text = LSPTextEdits.apply(edits, to: text)
                changed += 1
            } else {
                let result = await Task.detached { () -> Bool in
                    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
                    let new = LSPTextEdits.apply(edits, to: text)
                    guard new != text else { return false }
                    return (try? new.write(toFile: path, atomically: true, encoding: .utf8)) != nil
                }.value
                if result { changed += 1 }
            }
        }
        syncDirtyFlags()
        return changed
    }
}
