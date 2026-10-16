// @author ixxxxoooo
// 文件日志写入器:串行队列异步追加、按大小轮转、按天数与个数清理。

import Foundation

/// 文件写入器。所有写入在私有串行队列上完成,调用方永不阻塞。
public final class LogFileWriter: @unchecked Sendable {
    public let directory: URL
    private let prefix: String
    private let maxBytes: Int
    private let maxFiles: Int
    private let retentionDays: Int
    private let queue = DispatchQueue(label: "com.ixxxxoooo.OhMyAgent.logwriter", qos: .utility)
    private var handle: FileHandle?
    private var currentPath: String?
    private var currentSize = 0

    /// 创建写入器。
    /// - Parameters:
    ///   - directory: 日志目录(不存在会创建)
    ///   - prefix: 文件名前缀,如 `oma`
    ///   - maxBytes: 单文件上限,超过后轮转
    ///   - maxFiles: 最多保留的文件个数
    ///   - retentionDays: 最长保留天数
    public init(directory: URL, prefix: String = "oma", maxBytes: Int = 10 * 1024 * 1024, maxFiles: Int = 5, retentionDays: Int = 7) {
        self.directory = directory
        self.prefix = prefix
        self.maxBytes = max(maxBytes, 1024)
        self.maxFiles = max(maxFiles, 1)
        self.retentionDays = max(retentionDays, 1)
        queue.async { [self] in
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            cleanup()
        }
    }

    deinit { try? handle?.close() }

    /// 异步追加一行。
    /// - Parameter line: 不含换行的文本
    public func append(_ line: String) {
        queue.async { [self] in write(line + "\n") }
    }

    /// 等待已入队的写入全部完成(测试与退出时使用)。
    public func flush() { queue.sync {} }

    /// 当前日期对应的文件名。
    private func fileName(for date: Date = Date(), index: Int = 0) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd"
        let base = "\(prefix)-\(formatter.string(from: date))"
        return index == 0 ? "\(base).log" : "\(base).\(index).log"
    }

    /// 在队列内执行实际写入。
    private func write(_ text: String) {
        let path = directory.appendingPathComponent(fileName()).path
        if currentPath != path || handle == nil { open(path) }
        guard handle != nil, let data = text.data(using: .utf8) else { return }
        if currentSize + data.count > maxBytes, currentSize > 0 {
            rotate(path)
            open(path)
        }
        guard let target = self.handle else { return }
        do {
            try target.write(contentsOf: data)
            currentSize += data.count
        } catch {
            // 日志本身失败不能影响业务;重新打开一次再放弃
            self.handle = nil
            currentPath = nil
        }
    }

    /// 打开(必要时创建)日志文件并定位到末尾。
    private func open(_ path: String) {
        try? handle?.close()
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let newHandle = FileHandle(forWritingAtPath: path) else { handle = nil; currentPath = nil; return }
        let end = (try? newHandle.seekToEnd()) ?? 0
        handle = newHandle
        currentPath = path
        currentSize = Int(end)
    }

    /// 轮转:`x.log` → `x.1.log` → `x.2.log`…,超出个数的最旧文件删除。
    private func rotate(_ path: String) {
        try? handle?.close()
        handle = nil
        let fm = FileManager.default
        let base = (path as NSString).deletingPathExtension
        let limit = maxFiles - 1
        if limit <= 0 { try? fm.removeItem(atPath: path); return }
        try? fm.removeItem(atPath: "\(base).\(limit).log")
        var index = limit - 1
        while index >= 1 {
            try? fm.moveItem(atPath: "\(base).\(index).log", toPath: "\(base).\(index + 1).log")
            index -= 1
        }
        try? fm.moveItem(atPath: path, toPath: "\(base).1.log")
    }

    /// 清理过期与超量文件。
    private func cleanup() {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let mine = urls.filter { $0.lastPathComponent.hasPrefix("\(prefix)-") && $0.pathExtension == "log" }
        let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86_400)
        var survivors: [(URL, Date)] = []
        for url in mine {
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            if date < cutoff { try? fm.removeItem(at: url) } else { survivors.append((url, date)) }
        }
        let overflow = survivors.sorted { $0.1 > $1.1 }.dropFirst(maxFiles * 3)
        for (url, _) in overflow { try? fm.removeItem(at: url) }
    }
}
