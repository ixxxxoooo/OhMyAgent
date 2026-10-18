// @author ixxxxoooo
// 终端会话视图模型:
// - 内置终端(ACP `terminal/*`):命令运行期间以 150ms 间隔拉取输出快照,结束后停止轮询;
// - 外部终端(适配器自己执行的 Bash,经 `_meta` 报告):输出由会话推送;后台命令跟读它的输出文件。

import ACPKit
import AgentHost
import Foundation
import Observation

/// 终端会话(供工具卡片中的终端视图使用)。
@MainActor
@Observable
public final class TerminalSession: Identifiable {
    public nonisolated let id: String
    public internal(set) var command: String
    /// 创建时间(任务坞显示已运行时长)
    public let startedAt = Date()
    public private(set) var output = ""
    public private(set) var truncated = false
    /// 输出发生「非追加式」变化的次数(头部被截断、整段被替换、快照不是上一次的延伸);
    /// 逐字节镜像输出的视图据此判断要不要整屏重绘
    public private(set) var discontinuity = 0
    public private(set) var exitCode: Int?
    public private(set) var signal: String?
    public private(set) var isRunning = true
    /// 是否在沙箱内运行
    public internal(set) var sandboxed = false
    /// 沙箱运行且输出像被拦截(工具卡片据此显示「放行一次」)
    public var sandboxBlocked: Bool { sandboxed && !isRunning && TerminalSandbox.looksBlocked(output: output, exitCode: exitCode) }
    private var pollTask: Task<Void, Never>?
    /// 是否外部终端(命令由 Agent 自己执行,这里只镜像输出;不能由本应用终止)
    public let isExternal: Bool
    /// 正在跟读的输出文件(后台命令);非 nil 表示这是后台命令
    public private(set) var followedPath: String?
    /// 是否后台命令
    public var isBackground: Bool { followedPath != nil }
    @ObservationIgnored private var tailTask: Task<Void, Never>?
    @ObservationIgnored private var tailOffset: UInt64 = 0
    /// 跟读时尚未凑成完整 UTF-8 字符的尾部字节
    @ObservationIgnored private var pendingBytes = Data()
    /// 外部终端输出的字符数上限(超出从头部丢弃)
    static let externalOutputLimit = 1_000_000

    /// - Parameters:
    ///   - id: 终端标识
    ///   - command: 命令文本(外部终端可稍后由 `updateCommand` 补全)
    ///   - isExternal: 是否外部终端(命令由 Agent 自己执行,这里只镜像输出)
    public init(id: String, command: String, isExternal: Bool = false) {
        self.id = id
        self.command = command
        self.isExternal = isExternal
    }

    /// 开始轮询。
    /// - Parameter manager: 终端管理器
    func startPolling(manager: TerminalManager) {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                let snapshot = await manager.peek(self?.id ?? "")
                guard let self else { return }
                guard let snapshot else { self.isRunning = false; return }
                self.apply(snapshot)
                if snapshot.exitCode != nil || snapshot.signal != nil { self.isRunning = false; return }
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
    }

    private func apply(_ snapshot: TerminalOutputSnapshot) {
        if output != snapshot.output {
            if !snapshot.output.hasPrefix(output) { discontinuity += 1 }
            output = snapshot.output
        }
        truncated = snapshot.truncated
        exitCode = snapshot.exitCode
        signal = snapshot.signal
    }

    /// 停止轮询。
    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: 外部终端

    /// 更新命令文本(工具输入流式到达,首个事件时命令可能还是空的)。
    func updateCommand(_ text: String) {
        if !text.isEmpty, text != command { command = text }
    }

    /// 追加输出;超过上限时丢弃头部并标记截断。
    func appendExternal(_ text: String) {
        guard !text.isEmpty else { return }
        output += text
        if output.count > Self.externalOutputLimit {
            output = String(output.suffix(Self.externalOutputLimit))
            truncated = true
            discontinuity += 1
        }
    }

    /// 用整段输出替换(前台命令结束时一次性给出)。
    func replaceExternal(_ text: String) {
        discontinuity += 1
        output = ""
        appendExternal(text)
    }

    /// 命令结束:先把输出文件里剩余的内容读完,再标记结束,避免丢最后一段。
    /// - Parameters:
    ///   - exitCode: 退出码(未知为 nil)
    ///   - signal: 终止信号
    func finishExternal(exitCode: Int?, signal: String?) {
        guard isRunning else { return }
        self.exitCode = exitCode
        self.signal = signal
        tailTask?.cancel()
        tailTask = nil
        guard let path = followedPath else { isRunning = false; return }
        Task { [weak self] in
            while let self, let chunk = await Self.readAppended(path: path, offset: self.tailOffset), !chunk.data.isEmpty {
                self.tailOffset = chunk.newOffset
                self.ingest(chunk)
            }
            self?.isRunning = false
        }
    }

    /// 开始跟读后台命令的输出文件(约 300ms 一次)。同一路径重复调用无效。
    /// - Parameter path: 输出文件的绝对路径
    func followFile(_ path: String) {
        guard followedPath != path else { return }
        followedPath = path
        tailOffset = 0
        tailTask?.cancel()
        tailTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if let chunk = await Self.readAppended(path: path, offset: self.tailOffset) {
                    self.tailOffset = chunk.newOffset
                    self.ingest(chunk)
                }
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
    }

    private func ingest(_ chunk: TailChunk) {
        if chunk.skippedHead { truncated = true }
        pendingBytes.append(chunk.data)
        let cut = Self.completeUTF8Length(pendingBytes)
        guard cut > 0 else { return }
        let text = String(decoding: pendingBytes.prefix(cut), as: UTF8.self)
        pendingBytes = Data(pendingBytes.dropFirst(cut))
        appendExternal(text)
    }

    /// 一次读取的结果。
    struct TailChunk: Sendable {
        var data: Data
        var newOffset: UInt64
        /// 文件比上限大,只读了末尾
        var skippedHead = false
    }

    /// 读取文件在 `offset` 之后新增的内容(在后台线程执行,单次最多 256 KiB)。
    /// 首次读取遇到超大文件时只取末尾 1 MiB。文件被截断(变小)时从头重读。
    @concurrent
    static func readAppended(path: String, offset: UInt64) async -> TailChunk? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        do {
            let size = try handle.seekToEnd()
            var start = offset
            var skipped = false
            if size < start { start = 0 }
            if start == 0, size > 1 << 20 { start = size - (1 << 20); skipped = true }
            guard size > start else { return start == offset ? nil : TailChunk(data: Data(), newOffset: start) }
            try handle.seek(toOffset: start)
            let data = try handle.read(upToCount: 256 * 1024) ?? Data()
            return TailChunk(data: data, newOffset: start + UInt64(data.count), skippedHead: skipped)
        } catch {
            return nil
        }
    }

    /// 缓冲里「完整 UTF-8 字符」的字节数:末尾不完整的多字节字符留到下次。
    /// - Parameter data: 待解码的字节
    /// - Returns: 可安全解码的前缀长度
    static func completeUTF8Length(_ data: Data) -> Int {
        let n = data.count
        var i = n - 1
        var back = 0
        while i >= 0, back < 4 {
            let byte = data[data.startIndex + i]
            if byte & 0b1100_0000 == 0b1000_0000 { i -= 1; back += 1; continue }  // 续字节,继续向前找首字节
            let need = byte >= 0xF0 ? 4 : (byte >= 0xE0 ? 3 : (byte >= 0xC0 ? 2 : 1))
            return n - i >= need ? n : i
        }
        return n
    }
}
