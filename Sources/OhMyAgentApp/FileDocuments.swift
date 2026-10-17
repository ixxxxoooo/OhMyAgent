// @author ixxxxoooo
// 文件文档仓库:每个打开的文件一份内存文档(文本、已保存文本、磁盘修改时间),
// 标签切换/重建不丢失未保存的编辑;支持保存、外部修改检测与重新载入。

import AppKit
import Foundation
import Observation
import OMLog
import WorkbenchKit

/// 一个已打开文件的内存状态。
@MainActor
@Observable
final class FileDocument {
    let path: String
    /// 编辑器中的当前文本(尚未加载为 nil)
    var text: String?
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

    init(path: String) { self.path = path }

    /// 是否有未保存的修改。
    var isDirty: Bool {
        guard let text else { return false }
        return text != savedText
    }

    fileprivate func apply(loaded: String, modified: Date?) {
        text = loaded
        savedText = loaded
        diskModified = modified
        externalChange = false
        loadError = nil
    }

    fileprivate func markSaved(_ content: String, modified: Date?) {
        savedText = content
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
    func document(for path: String) -> FileDocument {
        if let doc = documents[path] { return doc }
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

    private struct DiskState: Sendable { var text: String?; var modified: Date?; var size: Int }

    private nonisolated static func readDisk(_ path: String) -> DiskState {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let modified = attrs?[.modificationDate] as? Date
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        guard let data = FileManager.default.contents(atPath: path) else { return DiskState(text: nil, modified: modified, size: size) }
        return DiskState(text: String(data: data, encoding: .utf8), modified: modified, size: size)
    }

    private func load(_ doc: FileDocument) async {
        let path = doc.path
        let started = ContinuousClock.now
        let state = await Task.detached(priority: .userInitiated) { Self.readDisk(path) }.value
        guard let text = state.text else {
            doc.loadError = String(localized: "无法读取文件(可能已被删除或不是文本文件)")
            Log.editor.warning("文件读取失败", ["path": path])
            return
        }
        doc.isReadOnly = state.size > Self.editableLimit
        doc.apply(loaded: text, modified: state.modified)
        Log.editor.info("文件已加载", ["path": path, "bytes": "\(state.size)", "ms": "\(Int((ContinuousClock.now - started).seconds * 1000))"])
    }

    // MARK: 外部修改

    /// 对比磁盘修改时间:无本地编辑则静默刷新,有编辑则标记冲突。
    func checkExternalChange(_ path: String) async {
        guard let doc = documents[path], doc.text != nil else { return }
        let state = await Task.detached(priority: .utility) { Self.readDisk(path) }.value
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
        guard let doc = documents[path], let text = doc.text, !doc.isReadOnly else { return false }
        guard doc.isDirty else { return true }
        let started = ContinuousClock.now
        let outcome = await Task.detached(priority: .userInitiated) { () -> Result<Date?, any Error> in
            do {
                try text.write(toFile: path, atomically: true, encoding: .utf8)
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
