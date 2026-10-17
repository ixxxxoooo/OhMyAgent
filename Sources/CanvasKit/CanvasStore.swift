// @author ixxxxoooo
// Canvas 落盘存储:`<目录>/<id>.canvas.json`,原子写入;默认目录 `~/Library/Application Support/OhMyAgent/canvases`。
// 无状态(值类型),可在任意线程使用;磁盘读写由调用方放在后台线程。

import Foundation

public struct CanvasStore: Sendable {
    public let directory: URL

    /// - Parameter directory: 存储目录(不存在时写入前自动创建)
    public init(directory: URL) { self.directory = directory }

    /// 默认存储目录。
    /// - Parameter home: 可注入的用户主目录(测试/演示隔离);nil 取系统 Application Support
    public static func defaultDirectory(home: URL? = nil) -> URL {
        let base = home?.appendingPathComponent("Library/Application Support", isDirectory: true)
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("OhMyAgent/canvases", isDirectory: true)
    }

    // MARK: 标识

    /// 合法标识:小写字母/数字/连字符,首字符为字母或数字,长度 ≤ 64。
    /// - Parameter id: 待校验标识
    public static func isValid(id: String) -> Bool {
        guard !id.isEmpty, id.count <= 64, let first = id.unicodeScalars.first else { return false }
        func ok(_ scalar: Unicode.Scalar, allowHyphen: Bool) -> Bool {
            (scalar.value >= 97 && scalar.value <= 122) || (scalar.value >= 48 && scalar.value <= 57) || (allowHyphen && scalar == "-")
        }
        return ok(first, allowHyphen: false) && id.unicodeScalars.allSatisfy { ok($0, allowHyphen: true) }
    }

    /// 由标题生成标识前缀:仅保留 ASCII 字母数字,其余折叠为连字符;全是中文等字符时回退 `canvas`。
    /// - Parameter title: 标题
    public static func slug(_ title: String) -> String {
        var result = ""
        var lastHyphen = true
        for scalar in title.lowercased().unicodeScalars {
            if (scalar.value >= 97 && scalar.value <= 122) || (scalar.value >= 48 && scalar.value <= 57) {
                result.unicodeScalars.append(scalar)
                lastHyphen = false
            } else if !lastHyphen {
                result += "-"
                lastHyphen = true
            }
        }
        while result.hasSuffix("-") { result.removeLast() }
        return result.isEmpty ? "canvas" : String(result.prefix(40))
    }

    private func url(for id: String) -> URL { directory.appendingPathComponent("\(id).canvas.json") }

    // MARK: 读写

    /// 新建画布。
    /// - Parameters:
    ///   - title: 标题(非空)
    ///   - blocks: 已校验的块
    ///   - projectPath: 所属项目路径
    /// - Returns: 已落盘的文档
    /// - Throws: `CanvasError`(参数不合法)或文件错误
    public func create(title: String, blocks: [CanvasBlock], projectPath: String?) throws -> CanvasDocument {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CanvasError("title 不能为空") }
        let normalized = try CanvasParser.validate(blocks)
        var id = Self.slug(trimmed) + "-" + String(UUID().uuidString.prefix(6)).lowercased()
        while FileManager.default.fileExists(atPath: url(for: id).path) { id = Self.slug(trimmed) + "-" + String(UUID().uuidString.prefix(6)).lowercased() }
        let document = CanvasDocument(id: id, title: trimmed, blocks: normalized, projectPath: projectPath)
        try write(document)
        return document
    }

    /// 更新画布:可改标题、整体替换块、或在末尾追加块。
    /// - Parameters:
    ///   - id: 画布标识
    ///   - title: 新标题(nil 不改)
    ///   - blocks: 整体替换的块(nil 不替换)
    ///   - appendBlocks: 追加到末尾的块(与 `blocks` 同时给出时先替换后追加)
    /// - Returns: 更新后的文档
    /// - Throws: `CanvasError` 或文件错误
    public func update(id: String, title: String?, blocks: [CanvasBlock]?, appendBlocks: [CanvasBlock]?) throws -> CanvasDocument {
        var document = try load(id: id)
        if let title {
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw CanvasError("title 不能为空") }
            document.title = trimmed
        }
        if let blocks { document.blocks = blocks }
        if let appendBlocks { document.blocks += appendBlocks }
        document.blocks = try CanvasParser.validate(document.blocks)
        document.updatedAt = Date()
        document.revision += 1
        try write(document)
        return document
    }

    /// 读取画布。
    /// - Parameter id: 画布标识
    /// - Throws: `CanvasError`(标识非法/不存在/损坏)
    public func load(id: String) throws -> CanvasDocument {
        guard Self.isValid(id: id) else { throw CanvasError("画布标识不合法:\(id)") }
        let location = url(for: id)
        guard let data = try? Data(contentsOf: location) else { throw CanvasError("画布不存在:\(id)") }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do { return try decoder.decode(CanvasDocument.self, from: data) } catch { throw CanvasError("画布文件已损坏:\(id)") }
    }

    /// 列出画布(按更新时间倒序)。
    /// - Parameter projectPath: 只列该项目的画布;nil 列全部
    public func list(projectPath: String? = nil) -> [CanvasSummary] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var result: [CanvasSummary] = []
        for file in files where file.lastPathComponent.hasSuffix(".canvas.json") {
            let id = String(file.lastPathComponent.dropLast(".canvas.json".count))
            guard let document = try? load(id: id) else { continue }
            if let projectPath, document.projectPath != projectPath { continue }
            result.append(CanvasSummary(id: id, title: document.title, projectPath: document.projectPath,
                                        updatedAt: document.updatedAt, blockCount: document.blockCount))
        }
        return result.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// 删除画布(不存在时静默)。
    /// - Parameter id: 画布标识
    public func delete(id: String) {
        guard Self.isValid(id: id) else { return }
        try? FileManager.default.removeItem(at: url(for: id))
    }

    /// 导出为美化后的 JSON 源码(「源码」视图与复制用)。
    /// - Parameter document: 文档
    public static func source(of document: CanvasDocument) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(document) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// 写入(或覆盖)文档;标识必须合法。演示数据预置等场景使用固定标识时调用。
    /// - Parameter document: 文档
    /// - Throws: `CanvasError`(标识不合法)或文件错误
    public func save(_ document: CanvasDocument) throws {
        guard Self.isValid(id: document.id) else { throw CanvasError("画布标识不合法:\(document.id)") }
        try write(document)
    }

    private func write(_ document: CanvasDocument) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(document).write(to: url(for: document.id), options: .atomic)
    }
}
