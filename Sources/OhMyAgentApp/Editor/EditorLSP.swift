// @author ixxxxoooo
// 文件标签与语言服务器的桥接:位置换算、诊断转换、文档同步(防抖)、hover/定义/补全。

import ChatKit
import EditorKit
import Foundation
import LSPKit
import Observation
import OMLog

/// UTF-16 偏移 ↔ LSP 位置换算与诊断转换(纯函数,便于测试)。
enum LSPTextMapping {
    /// 偏移转 LSP 位置。
    /// - Parameters:
    ///   - offset: UTF-16 偏移(越界会被夹取)
    ///   - index: 文本行索引
    static func position(offset: Int, in index: LineIndex) -> LSPPosition {
        let clamped = min(max(offset, 0), index.length)
        let line = index.line(containing: clamped)
        return LSPPosition(line: line, character: clamped - index.lineStarts[line])
    }

    /// LSP 位置转偏移;行越界夹取到文末,列越界夹取到行尾(不含换行)。
    /// - Parameters:
    ///   - position: LSP 位置
    ///   - index: 文本行索引
    static func offset(of position: LSPPosition, in index: LineIndex) -> Int {
        guard position.line >= 0 else { return 0 }
        guard position.line < index.lineCount else { return index.length }
        let start = index.lineStarts[position.line]
        let end = position.line + 1 < index.lineCount ? index.lineStarts[position.line + 1] - 1 : index.length
        return min(start + max(position.character, 0), max(end, start))
    }

    /// 把 LSP 诊断转换为编辑器诊断。
    static func editorDiagnostics(_ items: [LSPDiagnostic], in index: LineIndex) -> [EditorDiagnostic] {
        items.map { item in
            let start = offset(of: item.range.start, in: index)
            let end = max(offset(of: item.range.end, in: index), start)
            let severity = EditorDiagnostic.Severity(rawValue: item.effectiveSeverity.rawValue) ?? .error
            let message = item.source.map { "\(item.message)  (\($0))" } ?? item.message
            return EditorDiagnostic(range: NSRange(location: start, length: end - start), severity: severity, message: message)
        }
    }
}

/// 一个文件标签的语言服务器会话。
@MainActor
@Observable
final class EditorLSPController {
    /// 服务器状态,供底部状态条展示。
    enum Status: Equatable {
        case off
        case starting
        case ready(String)
        case unavailable(String)
        case failed(String)
    }

    let path: String
    let projectRoot: String
    @ObservationIgnored private let manager: LSPManager
    private(set) var status: Status = .off
    private(set) var diagnostics: [EditorDiagnostic] = []

    /// 错误数。
    var errorCount: Int { diagnostics.filter { $0.severity == .error }.count }
    /// 警告数。
    var warningCount: Int { diagnostics.filter { $0.severity == .warning }.count }

    /// 跳转到其它位置:(绝对路径, 行号 1 起)。
    @ObservationIgnored var openLocation: ((String, Int) -> Void)?

    @ObservationIgnored private var handle: LSPDocumentHandle?
    @ObservationIgnored private var currentText = ""
    @ObservationIgnored private var syncedText = ""
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var diagnosticsTask: Task<Void, Never>?
    @ObservationIgnored private var closing = false

    /// - Parameters:
    ///   - path: 文件绝对路径
    ///   - projectRoot: 所属项目根目录
    ///   - manager: 语言服务器管理器(测试可注入)
    init(path: String, projectRoot: String, manager: LSPManager = .shared) {
        self.path = path
        self.projectRoot = projectRoot
        self.manager = manager
    }

    /// 该路径是否有可用的语言服务器类型。
    static func isSupported(path: String) -> Bool { LSPServerKind.kind(forPath: path) != nil }

    // MARK: 生命周期

    /// 启动服务器(必要时)并打开文档。
    /// - Parameter text: 当前文本
    func attach(text: String) async {
        guard handle == nil, status == .off || status == .starting else { return }
        closing = false
        currentText = text
        syncedText = text
        status = .starting
        let span = Log.perf.span("语言服务器附加", warnMs: 300, ["file": (path as NSString).lastPathComponent, "bytes": "\(text.utf8.count)"])
        let stored = UserDefaults.standard.integer(forKey: ClientPrefs.Key.lspMaxWorkspaces)
        await manager.setMaxClients(stored == 0 ? 4 : stored)
        let result = await manager.open(path: path, projectRoot: projectRoot, text: text)
        span.end()
        if closing {
            // 等待期间视图已消失:若已打开则立刻关闭
            if case .ready(let opened) = result { await manager.close(opened) }
            return
        }
        switch result {
        case .unsupported:
            status = .off
        case .unavailable(let kind):
            status = .unavailable(kind.installHint)
            Log.lsp.info("语言服务器未安装", ["kind": kind.rawValue, "file": (path as NSString).lastPathComponent])
        case .failed(_, let message):
            status = .failed(message)
        case .ready(let opened):
            handle = opened
            let name = await opened.client.serverName ?? opened.kind.displayName
            status = .ready(name)
            let updates = await opened.client.diagnosticUpdates()
            let uri = opened.uri
            diagnosticsTask = Task { [weak self] in
                for await update in updates where update.uri == uri {
                    self?.apply(update.diagnostics)
                }
                self?.serverStopped()
            }
            if let probe = ProcessInfo.processInfo.environment["OMA_LSP_PROBE"] { Task { await self.runProbe(probe) } }
        }
    }

    /// 调试钩子 `OMA_LSP_PROBE=行:列`(0 起):在该位置依次发起 hover/定义/补全,把结果写入日志,用于无人值守验证整条链路。
    private func runProbe(_ spec: String) async {
        let parts = spec.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return }
        try? await Task.sleep(for: .seconds(2))
        let index = LineIndex(text: currentText)
        let offset = LSPTextMapping.offset(of: LSPPosition(line: parts[0], character: parts[1]), in: index)
        let hoverText = await hover(at: offset)
        let completions = await completion(at: offset)
        var definition = "-"
        if let handle, let first = try? await handle.client.definition(uri: handle.uri, at: LSPTextMapping.position(offset: offset, in: index)).first {
            definition = "\((first.uri as NSString).lastPathComponent):\(first.range.start.line + 1)"
        }
        Log.lsp.info("LSP 探针", ["offset": "\(offset)", "hover": String((hoverText ?? "nil").prefix(120)), "definition": definition, "completions": "\(completions.count)", "first": completions.first?.insertText ?? "-", "diagnostics": "\(diagnostics.count)"])
    }

    /// 视图消失:关闭文档。
    func detach() {
        closing = true
        syncTask?.cancel()
        diagnosticsTask?.cancel()
        let opened = handle
        handle = nil
        diagnostics = []
        status = .off
        if let opened { Task { await manager.close(opened) } }
    }

    private func serverStopped() {
        guard handle != nil else { return }
        handle = nil
        diagnostics = []
        status = .failed(String(localized: "语言服务器已退出"))
    }

    private func apply(_ items: [LSPDiagnostic]) {
        diagnostics = LSPTextMapping.editorDiagnostics(items, in: LineIndex(text: currentText))
    }

    // MARK: 同步

    /// 文本变更:防抖后整篇同步给服务器。
    func textChanged(_ text: String) {
        currentText = text
        guard handle != nil, text != syncedText else { return }
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await self?.flush()
        }
    }

    /// 立刻把未同步的文本发给服务器(查询前调用,保证位置一致)。
    private func flush() async {
        guard let handle, currentText != syncedText else { return }
        let previous = syncedText
        syncedText = currentText
        // 服务器支持增量同步时只发一段变更;否则(或算不出差异)整篇同步
        if let change = LSPTextDiff.change(from: previous, to: currentText) {
            await handle.client.didChange(uri: handle.uri, change: change, fullText: currentText)
        } else {
            await handle.client.didChange(uri: handle.uri, text: currentText)
        }
    }

    /// 保存后通知服务器。
    func didSave() {
        guard let handle else { return }
        let text = currentText
        Task { await handle.client.didSave(uri: handle.uri, text: text) }
    }

    // MARK: 查询

    /// 供编辑器使用的回调集合。服务器未就绪时返回空实现。
    var features: EditorLanguageFeatures {
        guard handle != nil else { return EditorLanguageFeatures() }
        return EditorLanguageFeatures(
            hover: { [weak self] offset in await self?.hover(at: offset) },
            definition: { [weak self] offset in self?.jumpToDefinition(at: offset) },
            completion: { [weak self] offset in await self?.completion(at: offset) ?? [] },
            signatureHelp: { [weak self] offset in await self?.signatureHelp(at: offset) }
        )
    }

    // MARK: 扩展能力(IDE 命令:引用 / 符号 / 重命名 / 格式化)

    /// 当前缓冲区文本(与服务器同步的最新版本)。
    var text: String { currentText }

    /// 服务器是否就绪(可发扩展请求)。
    var isReady: Bool { handle != nil }

    /// 文档符号(大纲)。
    func symbols() async -> [LSPSymbol] {
        guard let handle else { return [] }
        await flush()
        do { return try await handle.client.documentSymbols(uri: handle.uri) } catch {
            Log.lsp.debug("文档符号失败", ["error": error.localizedDescription])
            return []
        }
    }

    /// 查找某偏移处符号的引用。
    /// - Parameter offset: UTF-16 偏移
    func references(at offset: Int) async -> [LSPLocation] {
        guard let handle else { return [] }
        await flush()
        let position = LSPTextMapping.position(offset: offset, in: LineIndex(text: currentText))
        do { return try await handle.client.references(uri: handle.uri, at: position) } catch {
            Log.lsp.warning("查找引用失败", ["error": error.localizedDescription])
            return []
        }
    }

    /// 重命名某偏移处的符号,返回需应用的工作区编辑(失败为 nil)。
    /// - Parameters:
    ///   - offset: UTF-16 偏移
    ///   - newName: 新名称
    func rename(at offset: Int, to newName: String) async -> LSPWorkspaceEdit? {
        guard let handle else { return nil }
        await flush()
        let position = LSPTextMapping.position(offset: offset, in: LineIndex(text: currentText))
        do { return try await handle.client.rename(uri: handle.uri, at: position, newName: newName) } catch {
            Log.lsp.warning("重命名失败", ["error": error.localizedDescription])
            return nil
        }
    }

    /// 整篇格式化,返回要应用的编辑(失败为空)。
    /// - Parameters:
    ///   - tabSize: 缩进宽度
    ///   - insertSpaces: 是否用空格缩进
    func formatEdits(tabSize: Int, insertSpaces: Bool) async -> [LSPTextEdit] {
        guard let handle else { return [] }
        await flush()
        do { return try await handle.client.formatting(uri: handle.uri, tabSize: tabSize, insertSpaces: insertSpaces) } catch {
            Log.lsp.warning("格式化失败", ["error": error.localizedDescription])
            return []
        }
    }

    /// 光标处的签名帮助。
    /// - Parameter offset: UTF-16 偏移
    func signatureHelp(at offset: Int) async -> EditorSignature? {
        guard let handle else { return nil }
        await flush()
        let position = LSPTextMapping.position(offset: offset, in: LineIndex(text: currentText))
        do {
            guard let help = try await handle.client.signatureHelp(uri: handle.uri, at: position) else { return nil }
            return EditorSignature(label: help.label, activeParameter: help.activeParameter)
        } catch {
            Log.lsp.debug("签名帮助失败", ["error": error.localizedDescription])
            return nil
        }
    }

    /// 某范围的代码操作(快速修复/重构);带上与范围相交的诊断。
    /// - Parameter range: UTF-16 范围(光标处为空范围)
    func codeActions(in range: NSRange) async -> [LSPCodeAction] {
        guard let handle else { return [] }
        await flush()
        let index = LineIndex(text: currentText)
        let lspRange = LSPRange(start: LSPTextMapping.position(offset: range.location, in: index),
                                end: LSPTextMapping.position(offset: NSMaxRange(range), in: index))
        do {
            let all = await handle.client.diagnostics(for: handle.uri)
            let overlapping = all.filter { diagnostic in
                let start = LSPTextMapping.offset(of: diagnostic.range.start, in: index)
                let end = max(LSPTextMapping.offset(of: diagnostic.range.end, in: index), start)
                return start <= NSMaxRange(range) && end >= range.location
            }
            return try await handle.client.codeActions(uri: handle.uri, range: lspRange, diagnostics: overlapping)
        } catch {
            Log.lsp.warning("代码操作请求失败", ["error": error.localizedDescription])
            return []
        }
    }

    /// 补全缺少编辑的代码操作。
    func resolve(_ action: LSPCodeAction) async -> LSPCodeAction {
        guard let handle else { return action }
        return (try? await handle.client.resolve(action)) ?? action
    }

    private func hover(at offset: Int) async -> String? {
        guard let handle else { return nil }
        await flush()
        let position = LSPTextMapping.position(offset: offset, in: LineIndex(text: currentText))
        do { return try await handle.client.hover(uri: handle.uri, at: position) } catch {
            Log.lsp.debug("hover 失败", ["error": error.localizedDescription])
            return nil
        }
    }

    private func jumpToDefinition(at offset: Int) {
        Task { [weak self] in
            guard let self, let handle = self.handle else { return }
            await self.flush()
            let position = LSPTextMapping.position(offset: offset, in: LineIndex(text: self.currentText))
            do {
                let locations = try await handle.client.definition(uri: handle.uri, at: position)
                guard let target = locations.first, let targetPath = LSPURI.path(from: target.uri) else { return }
                self.openLocation?(targetPath, target.range.start.line + 1)
            } catch {
                Log.lsp.warning("跳转定义失败", ["error": error.localizedDescription])
            }
        }
    }

    private func completion(at offset: Int) async -> [EditorCompletion] {
        guard let handle else { return [] }
        await flush()
        let position = LSPTextMapping.position(offset: offset, in: LineIndex(text: currentText))
        do {
            let items = try await handle.client.completion(uri: handle.uri, at: position)
            return items.sorted { $0.sortText < $1.sortText }.map { EditorCompletion(label: $0.label, insertText: $0.insertText) }
        } catch {
            Log.lsp.debug("补全失败", ["error": error.localizedDescription])
            return []
        }
    }
}
