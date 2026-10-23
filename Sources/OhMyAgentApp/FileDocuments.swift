// @author ixxxxoooo
// 文件文档仓库:每个打开的文件一份内存文档(文本、已保存文本、磁盘修改时间),
// 标签切换/重建不丢失未保存的编辑;支持保存、外部修改检测与重新载入。

import AppKit
import EditorCore
import EditorKit
import Foundation
import Observation
import OMLog
import WorkbenchKit

/// 一个已打开文件的内存状态。
@MainActor
@Observable
final class FileDocument {
    let path: String
    /// 编辑器中的当前文本(尚未加载为 nil)。
    /// 原生引擎下它是 `editorDocument` 的字符串镜像(停止输入约 250ms 后同步),外部整体写入会反向应用到 rope 文档。
    var text: String? { didSet { textDidSet() } }
    /// 原生编辑器共享的 rope 文档(仅 native2 引擎创建)。
    @ObservationIgnored private(set) var editorDocument: EditorDocument?
    /// rope 文档的脏状态镜像(只在切换时变化,避免每次按键都触发视图刷新)。
    private var editorDirty = false
    @ObservationIgnored private var observerToken: Int?
    @ObservationIgnored private var mirrorTask: Task<Void, Never>?
    @ObservationIgnored private var mirroring = false
    /// 最近一次读取/保存时磁盘上的内容
    private(set) var savedText: String = ""
    /// 加载失败原因
    var loadError: String?
    /// 磁盘文件在此期间被外部修改(且本地有未保存编辑)
    var externalChange = false
    /// 超过大小上限时只读
    var isReadOnly = false
    /// 最近一次已知的磁盘修改时间
    fileprivate(set) var diskModified: Date?
    /// 读入时识别出的文本编码(保存时沿用,GBK/GB18030 文件不会被改写成 UTF-8)
    fileprivate(set) var encoding: String.Encoding = .utf8
    /// 读取进行中(避免重复发起)
    @ObservationIgnored fileprivate var isLoading = false
    /// 最近一次读取开始时间(失败后重试的节流依据)
    @ObservationIgnored fileprivate var lastLoadAttempt: ContinuousClock.Instant?

    init(path: String) { self.path = path }

    /// 是否有未保存的修改。
    var isDirty: Bool {
        if editorDocument != nil { return editorDirty }
        guard let text else { return false }
        return text != savedText
    }

    /// 取得(必要时创建)与原生编辑器共享的 rope 文档;文本尚未加载时返回 nil。
    func ensureEditorDocument() -> EditorDocument? {
        if let editorDocument { return editorDocument }
        guard let text else { return nil }
        let document = EditorDocument(text: text)
        // 以已保存文本为基准:读入时就有的差异(如 CRLF 规范化)不算修改。
        if text != savedText { editorDirty = true } else { document.markSaved() }
        editorDocument = document
        observerToken = document.addObserver { [weak self] _ in self?.editorChanged() }
        return document
    }

    /// rope 文档变化:更新脏标记并防抖同步字符串镜像。
    private func editorChanged() {
        guard let editorDocument else { return }
        if editorDirty != editorDocument.isDirty { editorDirty = editorDocument.isDirty }
        mirrorTask?.cancel()
        mirrorTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.syncFromEditor()
        }
    }

    /// 立刻把 rope 文档内容同步到字符串镜像(保存、对比、复制前调用)。
    func syncFromEditor() {
        mirrorTask?.cancel()
        guard let editorDocument else { return }
        let latest = editorDocument.textForSaving()
        guard latest != text else { return }
        mirroring = true
        text = latest
        mirroring = false
    }

    /// 字符串镜像被外部整体改写(磁盘重载、格式化、Agent 追加):同步到 rope 文档。
    private func textDidSet() {
        guard !mirroring, let editorDocument, let text else { return }
        _ = editorDocument.applyExternal(text: text, markSaved: false)
        if editorDirty != editorDocument.isDirty { editorDirty = editorDocument.isDirty }
    }

    fileprivate func apply(loaded: String, modified: Date?) {
        text = loaded
        savedText = loaded
        editorDocument?.markSaved()
        editorDirty = false
        diskModified = modified
        externalChange = false
        loadError = nil
    }

    fileprivate func markSaved(_ content: String, modified: Date?) {
        savedText = content
        editorDocument?.markSaved()
        editorDirty = false
        diskModified = modified
        externalChange = false
    }
}

@MainActor
@Observable
final class FileDocumentStore {
    static let shared = FileDocumentStore()
    /// 文本编辑的体积上限;更大的文件以只读方式展示。
    static let editableLimit = 5_000_000

    private(set) var documents: [String: FileDocument] = [:]

    /// 取得(必要时创建)文档,并触发首次读取。
    /// 之前读取失败的文档(如打开时文件还没写出来)再次打开时重新读取,不沿用失败结果。
    func document(for path: String) -> FileDocument {
        if let doc = documents[path] {
            // 视图每次求值都会调用这里:读取中或 1 秒内刚试过就不再重试
            if doc.text == nil, doc.loadError != nil, !doc.isLoading,
               doc.lastLoadAttempt.map({ ContinuousClock.now - $0 > .seconds(1) }) ?? true {
                Task { await load(doc) }
            }
            return doc
        }
        let doc = FileDocument(path: path)
        documents[path] = doc
        Task { await load(doc) }
        return doc
    }

    /// 所有未保存的文档。
    var dirtyDocuments: [FileDocument] { documents.values.filter(\.isDirty).sorted { $0.path < $1.path } }

    /// 丢弃文档(关闭标签且不保存时)。
    func discard(_ path: String) { documents[path] = nil }

    // MARK: 读取

    private struct DiskState: Sendable { var text: String?; var encoding: String.Encoding; var exists: Bool; var modified: Date?; var size: Int }

    private nonisolated static func readDisk(_ path: String) -> DiskState {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let modified = attrs?[.modificationDate] as? Date
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        guard let data = FileManager.default.contents(atPath: path) else {
            return DiskState(text: nil, encoding: .utf8, exists: attrs != nil, modified: modified, size: size)
        }
        let decoded = decodeText(data)
        return DiskState(text: decoded?.text, encoding: decoded?.encoding ?? .utf8, exists: true, modified: modified, size: size)
    }

    /// GB18030(兼容 GBK/GB2312)编码。
    nonisolated static let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))

    /// 识别文本编码并解码:UTF-8 → 带 BOM 的 UTF-16 → GB18030(中文 Windows 常见的 GBK 文件)。
    /// 含 NUL 字节的内容视为二进制,不做猜测。
    /// - Parameter data: 文件内容
    /// - Returns: 文本与编码;无法作为文本读取为 nil
    nonisolated static func decodeText(_ data: Data) -> (text: String, encoding: String.Encoding)? {
        if let text = String(data: data, encoding: .utf8) { return (text, .utf8) }
        // UTF-16 必须带 BOM 且字节数为偶数(奇数长度说明是二进制)
        if data.count.isMultiple(of: 2), data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]),
           let text = String(data: data, encoding: .utf16) { return (text, .utf16) }
        guard !data.prefix(8192).contains(0) else { return nil }
        if let text = String(data: data, encoding: gb18030) { return (text, gb18030) }
        return nil
    }

    private func load(_ doc: FileDocument) async {
        let path = doc.path
        let started = ContinuousClock.now
        doc.isLoading = true
        doc.lastLoadAttempt = started
        defer { doc.isLoading = false }
        let state = await Task.detached(priority: .userInitiated) { Self.readDisk(path) }.value
        guard let text = state.text else {
            doc.loadError = state.exists
                ? String(localized: "无法以文本方式读取该文件(可能是二进制文件或编码无法识别)")
                : String(localized: "文件不存在(可能尚未写入或已被删除),文件出现后会自动载入")
            Log.editor.warning("文件读取失败", ["path": path, "exists": "\(state.exists)", "bytes": "\(state.size)"])
            return
        }
        doc.isReadOnly = state.size > Self.editableLimit
        doc.encoding = state.encoding
        doc.apply(loaded: text, modified: state.modified)
        Log.editor.info("文件已加载", ["path": path, "bytes": "\(state.size)", "encoding": "\(state.encoding.rawValue)", "ms": "\(Int((ContinuousClock.now - started).seconds * 1000))"])
    }

    // MARK: 外部修改

    /// 对比磁盘修改时间:无本地编辑则静默刷新,有编辑则标记冲突。
    func checkExternalChange(_ path: String) async {
        guard let doc = documents[path] else { return }
        let state = await Task.detached(priority: .utility) { Self.readDisk(path) }.value
        if doc.text == nil {
            // 之前读取失败(文件当时还不存在或正在写入):现在能读了就载入,仍读不了保持原错误不重复记日志
            guard doc.loadError != nil, let text = state.text else { return }
            doc.isReadOnly = state.size > Self.editableLimit
            doc.encoding = state.encoding
            doc.apply(loaded: text, modified: state.modified)
            Log.editor.info("文件已可读取,已载入", ["path": path, "bytes": "\(state.size)"])
            return
        }
        guard let modified = state.modified, let known = doc.diskModified, modified > known else { return }
        guard let text = state.text, text != doc.savedText else {
            doc.diskModified = modified
            return
        }
        if doc.isDirty {
            doc.externalChange = true
            Log.editor.info("文件被外部修改且本地有未保存编辑", ["path": path])
        } else {
            doc.apply(loaded: text, modified: modified)
            Log.editor.info("文件被外部修改,已自动刷新", ["path": path])
        }
    }

    /// 放弃本地编辑,从磁盘重新载入。
    func reload(_ path: String) async {
        guard let doc = documents[path] else { return }
        await load(doc)
    }

    // MARK: 保存

    /// 保存文档到磁盘(原子写入)。
    /// - Returns: 是否成功
    @discardableResult
    func save(_ path: String) async -> Bool {
        guard let doc = documents[path], doc.text != nil, !doc.isReadOnly else { return false }
        guard doc.isDirty else { return true }
        doc.syncFromEditor()
        guard let text = doc.text else { return false }
        let encoding = doc.encoding
        let started = ContinuousClock.now
        let outcome = await Task.detached(priority: .userInitiated) { () -> Result<Date?, any Error> in
            do {
                try text.write(toFile: path, atomically: true, encoding: encoding)
                let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
                return .success(modified)
            } catch { return .failure(error) }
        }.value
        switch outcome {
        case .success(let modified):
            doc.markSaved(text, modified: modified)
            Log.editor.info("文件已保存", ["path": path, "bytes": "\(text.utf8.count)", "ms": "\(Int((ContinuousClock.now - started).seconds * 1000))"])
            return true
        case .failure(let error):
            Log.editor.error("文件保存失败", ["path": path, "error": error.localizedDescription])
            OMDialog.alert(title: String(localized: "无法保存文件"), message: error.localizedDescription, isError: true)
            return false
        }
    }

    /// 保存全部未保存文档。
    func saveAll() async -> Bool {
        var ok = true
        for doc in dirtyDocuments { if await !save(doc.path) { ok = false } }
        return ok
    }
}
