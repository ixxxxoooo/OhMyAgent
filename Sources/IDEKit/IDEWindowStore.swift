// @author ixxxxoooo
// `ide-windows.json` 的读写:原子写入;损坏时备份为 `.corrupt` 并回退为空状态;写盘由后台 actor 串行执行,
// 较新的快照永远不会被较旧的覆盖。

import Foundation
import OMLog

/// IDE 窗口状态文件存取。
public struct IDEWindowStore: Sendable {
    public let fileURL: URL

    /// - Parameter fileURL: 状态文件;默认 `AppEnv.supportDirectory/ide-windows.json`
    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultURL
    }

    /// 默认位置(随稳定版/开发版/演示沙盒隔离)。
    public static var defaultURL: URL {
        AppEnv.supportDirectory.appendingPathComponent("ide-windows.json")
    }

    /// 损坏文件的备份位置。
    public var corruptBackupURL: URL { fileURL.appendingPathExtension("corrupt") }

    /// 读取状态;文件不存在返回空状态;损坏(读取/解码失败或版本更新)时备份原文件并返回空状态。
    public func load() -> IDEWindowsState {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return IDEWindowsState() }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            var state = try decoder.decode(IDEWindowsState.self, from: data)
            guard state.version <= IDEWindowsState.currentVersion else {
                Log.app.warning("IDE 窗口状态版本较新,已忽略", ["version": "\(state.version)"])
                return IDEWindowsState()
            }
            for index in state.windows.indices { state.windows[index].clamp() }
            // 同一标识只保留第一份,防止手改文件造成重复窗口
            var seen = Set<UUID>()
            state.windows = state.windows.filter { seen.insert($0.id).inserted }
            return state
        } catch {
            Log.app.error("IDE 窗口状态读取失败,已备份并使用空状态", error: error, ["file": fileURL.lastPathComponent])
            backupCorruptFile()
            return IDEWindowsState()
        }
    }

    /// 写入状态(原子)。
    /// - Parameter state: 窗口状态
    public func save(_ state: IDEWindowsState) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(state).write(to: fileURL, options: .atomic)
    }

    private func backupCorruptFile() {
        let manager = FileManager.default
        do {
            if manager.fileExists(atPath: corruptBackupURL.path) { try manager.removeItem(at: corruptBackupURL) }
            try manager.copyItem(at: fileURL, to: corruptBackupURL)
        } catch {
            Log.app.error("备份损坏的 IDE 窗口状态失败", error: error, ["backup": corruptBackupURL.lastPathComponent])
        }
    }
}

/// 后台串行写盘:每次请求带递增代号,丢弃比已写入更旧的快照。
actor IDEWindowWriter {
    private let store: IDEWindowStore
    private var written = 0

    init(store: IDEWindowStore) { self.store = store }

    /// 写入快照。
    /// - Parameters:
    ///   - state: 窗口状态
    ///   - generation: 取快照时领取的代号
    func write(_ state: IDEWindowsState, generation: Int) {
        guard generation > written else { return }
        written = generation
        do { try store.save(state) } catch {
            Log.app.error("IDE 窗口状态写入失败", error: error, ["file": store.fileURL.lastPathComponent])
        }
    }
}
