// @author ixxxxoooo
// 语言服务器与原生编辑器(native2 引擎)的桥接:把 LSP 能力转换成 `NativeLanguageServices` 回调,
// 并处理服务器反向的 `workspace/applyEdit`(当前文件走编辑器可撤销编辑,其余文件直接改磁盘)。

import AppKit
import EditorKit
import Foundation
import LSPKit
import OMLog

/// 弱引用盒。
private final class WeakLSPController {
    weak var value: EditorLSPController?
    init(_ value: EditorLSPController) { self.value = value }
}

/// 已附加的会话(路径 → 控制器),供 `workspace/applyEdit` 路由。
@MainActor
private var attachedControllers: [String: WeakLSPController] = [:]

extension EditorLSPController {
    /// 服务器语义标记类型 → 语法类别(没有对应类别的标记不覆盖语法色)。
    static func syntaxKind(forSemanticType type: String) -> SyntaxKind? {
        switch type {
        case "namespace", "type", "class", "enum", "interface", "struct", "typeParameter": return .type
        case "function", "method", "macro": return .function
        case "property", "enumMember": return .property
        case "keyword", "modifier": return .keyword
        case "string", "regexp": return .string
        case "number": return .number
        case "comment": return .comment
        default: return nil
        }
    }

    /// 转换 LSP 位置范围为 UTF-16 范围。
    private func nsRange(_ range: LSPRange, in index: LineIndex) -> NSRange {
        let start = LSPTextMapping.offset(of: range.start, in: index)
        let end = max(LSPTextMapping.offset(of: range.end, in: index), start)
        return NSRange(location: start, length: end - start)
    }

    /// 转换服务器编辑为编辑器编辑。
    func nativeEdits(_ edits: [LSPTextEdit], in index: LineIndex) -> [NativeTextEdit] {
        edits.map { NativeTextEdit(range: nsRange($0.range, in: index), newText: $0.newText) }
    }

    /// 构建原生编辑器回调集合;服务器未就绪时为空集合。
    func makeNativeServices() -> NativeLanguageServices {
        var services = NativeLanguageServices()
        guard handle != nil else { return services }
        services.completionTriggers = completionTriggers.isEmpty ? [".", ":", "(", "<", "\"", "/", "@"] : completionTriggers
        services.onTypeTriggers = onTypeTriggers
        services.attach = { [weak self] editor in
            self?.nativeEditor = editor
            if let self { attachedControllers[self.path] = WeakLSPController(self) }
        }
        services.prepare = { [weak self] text in self?.textChanged(text()) }
        services.hover = { [weak self] offset in await self?.hover(at: offset) }
        services.definition = { [weak self] offset in await self?.nativeDefinition(at: offset) ?? [] }
        services.references = { [weak self] offset in await self?.nativeReferences(at: offset) ?? [] }
        services.openLocation = { [weak self] location in self?.openLocation?(location.path, location.line + 1) }
        services.completion = { [weak self] offset in await self?.nativeCompletion(at: offset) ?? [] }
        services.signatureHelp = { [weak self] offset in await self?.signatureHelp(at: offset) }
        services.codeActions = { [weak self] range in await self?.nativeCodeActions(in: range) ?? [] }
        services.runCodeAction = { [weak self] item in await self?.runNativeCodeAction(item) }
        services.inlayHints = { [weak self] range in await self?.nativeInlayHints(in: range) ?? [] }
        services.semanticSpans = { [weak self] in await self?.nativeSemanticSpans() ?? [] }
        services.format = { [weak self] range in await self?.nativeFormat(range) ?? [] }
        services.onTypeFormat = { [weak self] offset, character in await self?.nativeOnTypeFormat(offset: offset, character: character) ?? [] }
        return services
    }

    // MARK: 定义 / 引用

    private func nativeLocations(_ locations: [LSPLocation]) async -> [NativeLocation] {
        var cache: [String: [String]] = [:]
        var result: [NativeLocation] = []
        for location in locations.prefix(200) {
            guard let path = LSPURI.path(from: location.uri) else { continue }
            let line = location.range.start.line
            if cache[path] == nil {
                cache[path] = path == self.path
                    ? currentText.components(separatedBy: "\n")
                    : await Task.detached { (try? String(contentsOfFile: path, encoding: .utf8))?.components(separatedBy: "\n") ?? [] }.value
            }
            let preview = cache[path].flatMap { $0.indices.contains(line) ? $0[line] : nil } ?? ""
            result.append(NativeLocation(path: path, line: line, column: location.range.start.character, preview: String(preview.prefix(160))))
        }
        return result
    }

    private func nativeDefinition(at offset: Int) async -> [NativeLocation] {
        guard let handle else { return [] }
        await flush()
        let position = LSPTextMapping.position(offset: offset, in: LineIndex(text: currentText))
        do { return await nativeLocations(try await handle.client.definition(uri: handle.uri, at: position)) } catch {
            Log.lsp.warning("跳转定义失败", ["error": error.localizedDescription])
            return []
        }
    }

    private func nativeReferences(at offset: Int) async -> [NativeLocation] {
        await nativeLocations(await references(at: offset))
    }

    // MARK: 补全

    func nativeCompletion(at offset: Int) async -> [NativeCompletionItem] {
        guard let handle else { return [] }
        await flush()
        let index = LineIndex(text: currentText)
        let position = LSPTextMapping.position(offset: offset, in: index)
        do {
            let items = try await handle.client.completion(uri: handle.uri, at: position)
            return items.prefix(2_000).map { item in
                NativeCompletionItem(label: item.label, detail: item.detail, documentation: item.documentation,
                                     kind: NativeCompletionKind(rawValue: item.kind ?? 1) ?? .text, insertText: item.insertText,
                                     snippet: item.snippet, replaceRange: item.replaceRange.map { nsRange($0, in: index) },
                                     filterText: item.filterText, sortText: item.sortText)
            }
        } catch {
            Log.lsp.debug("补全失败", ["error": error.localizedDescription])
            return []
        }
    }

    // MARK: 代码操作

    private func nativeCodeActions(in range: NSRange) async -> [NativeCodeActionItem] {
        let actions = await codeActions(in: range)
        nativeActionCache = actions
        return actions.enumerated().map { index, action in
            NativeCodeActionItem(id: "\(index)", title: action.title, isQuickFix: action.kind?.hasPrefix("quickfix") == true, isPreferred: action.isPreferred)
        }.sorted { $0.isPreferred && !$1.isPreferred }
    }

    private func runNativeCodeAction(_ item: NativeCodeActionItem) async {
        guard let index = Int(item.id), nativeActionCache.indices.contains(index) else { return }
        let resolved = await resolve(nativeActionCache[index])
        guard let edit = resolved.edit, edit.editCount > 0 else { return }
        let files = await applyWorkspaceEdit(edit)
        Log.lsp.info("原生编辑器快速修复", ["title": item.title, "files": "\(files)"])
    }

    // MARK: 内嵌提示 / 语义着色 / 格式化

    private func nativeInlayHints(in range: NSRange) async -> [NativeInlayHint] {
        guard let handle else { return [] }
        await flush()
        let index = LineIndex(text: currentText)
        let lspRange = LSPRange(start: LSPTextMapping.position(offset: range.location, in: index),
                                end: LSPTextMapping.position(offset: NSMaxRange(range), in: index))
        do {
            let hints = try await handle.client.inlayHints(uri: handle.uri, range: lspRange)
            return hints.map { hint in
                let label = (hint.paddingLeft ? " " : "") + hint.label + (hint.paddingRight ? " " : "")
                return NativeInlayHint(offset: LSPTextMapping.offset(of: hint.position, in: index), label: label)
            }
        } catch {
            Log.lsp.debug("内嵌提示失败", ["error": error.localizedDescription])
            return []
        }
    }

    private func nativeSemanticSpans() async -> [NativeSemanticSpan] {
        guard let handle else { return [] }
        await flush()
        let index = LineIndex(text: currentText)
        do {
            let tokens = try await handle.client.semanticTokens(uri: handle.uri)
            var spans: [NativeSemanticSpan] = []
            spans.reserveCapacity(tokens.count)
            for token in tokens {
                guard let kind = Self.syntaxKind(forSemanticType: token.type) else { continue }
                let start = LSPTextMapping.offset(of: LSPPosition(line: token.line, character: token.character), in: index)
                spans.append(NativeSemanticSpan(range: NSRange(location: start, length: token.length), kind: kind))
            }
            return spans
        } catch {
            Log.lsp.debug("语义标记失败", ["error": error.localizedDescription])
            return []
        }
    }

    private func nativeFormat(_ range: NSRange?) async -> [NativeTextEdit] {
        guard let handle else { return [] }
        await flush()
        let index = LineIndex(text: currentText)
        do {
            let edits: [LSPTextEdit]
            if let range {
                let lspRange = LSPRange(start: LSPTextMapping.position(offset: range.location, in: index),
                                        end: LSPTextMapping.position(offset: NSMaxRange(range), in: index))
                edits = try await handle.client.rangeFormatting(uri: handle.uri, range: lspRange, tabSize: 4, insertSpaces: true)
            } else {
                edits = try await handle.client.formatting(uri: handle.uri, tabSize: 4, insertSpaces: true)
            }
            return nativeEdits(edits, in: index)
        } catch {
            Log.lsp.warning("格式化失败", ["error": error.localizedDescription])
            return []
        }
    }

    private func nativeOnTypeFormat(offset: Int, character: Character) async -> [NativeTextEdit] {
        guard let handle else { return [] }
        await flush()
        let index = LineIndex(text: currentText)
        do {
            let edits = try await handle.client.onTypeFormatting(uri: handle.uri, at: LSPTextMapping.position(offset: offset, in: index),
                                                                  character: String(character), tabSize: 4, insertSpaces: true)
            return nativeEdits(edits, in: index)
        } catch {
            Log.lsp.debug("输入时格式化失败", ["error": error.localizedDescription])
            return []
        }
    }

    // MARK: 应用工作区编辑

    /// 注册服务器反向 `workspace/applyEdit` 的处理者。
    func installEditBridge(_ opened: LSPDocumentHandle) async {
        let bridge = LSPEditBridge()
        bridge.set { edit in await EditorLSPController.applyAttached(edit) }
        await opened.client.setApplyEditBridge(bridge)
    }

    /// 路由服务器编辑:已附加原生编辑器的文件走编辑器,其余直接改磁盘。
    static func applyAttached(_ edit: LSPWorkspaceEdit) async -> Bool {
        var changed = 0
        for (uri, edits) in edit.changes {
            guard let path = LSPURI.path(from: uri) else { continue }
            if let target = attachedControllers[path]?.value {
                if target.applyLocal(edits) { changed += 1 }
            } else if await applyToDisk(path: path, edits: edits) {
                changed += 1
            }
        }
        return changed > 0
    }

    /// 应用本控制器对应文件的编辑(优先走原生编辑器,保证可撤销)。
    @MainActor
    func applyLocal(_ edits: [LSPTextEdit]) -> Bool {
        if let editor = nativeEditor {
            let converted = nativeEdits(edits, in: LineIndex(text: editor.currentText()))
            return editor.applyEdits(converted)
        }
        return false
    }

    private static func applyToDisk(path: String, edits: [LSPTextEdit]) async -> Bool {
        await Task.detached { () -> Bool in
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
            let updated = LSPTextEdits.apply(edits, to: text)
            guard updated != text else { return false }
            return (try? updated.write(toFile: path, atomically: true, encoding: .utf8)) != nil
        }.value
    }

    /// 注销原生编辑器句柄(视图消失)。
    func unregisterNative() {
        attachedControllers[path] = nil
        nativeEditor = nil
    }

    /// 应用一份工作区编辑(代码操作结果)。
    /// - Returns: 修改的文件数
    @discardableResult
    func applyWorkspaceEdit(_ edit: LSPWorkspaceEdit) async -> Int {
        var changed = 0
        for (uri, edits) in edit.changes {
            guard let path = LSPURI.path(from: uri) else { continue }
            if path == self.path, applyLocal(edits) { changed += 1 } else if path != self.path, await Self.applyToDisk(path: path, edits: edits) { changed += 1 }
        }
        return changed
    }
}
