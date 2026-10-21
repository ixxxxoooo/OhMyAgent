// @author ixxxxoooo
// LSP 传输:语言服务器子进程的 stdio(Content-Length 分帧),以及内存分帧回环(测试用)。
// 两者都实现 ACPKit 的 `ACPTransport`:每个完整 JSON 正文作为一行事件上抛,从而复用 `ACPConnection` 的 JSON-RPC 逻辑。

import ACPKit
import Foundation
import OMLog
import Synchronization

/// 线程安全的帧解码器盒子。
final class FrameDecoderBox: Sendable {
    private let state = Mutex(LSPFrameDecoder())

    func push(_ data: Data) -> [Data] { state.withLock { $0.push(data) } }
}

/// 语言服务器子进程传输。
public final class LSPStdioTransport: ACPTransport, @unchecked Sendable {
    private let launch: ProcessLaunch
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let writeQueue = DispatchQueue(label: "OhMyAgent.LSPStdioTransport.write")
    private let decoder = FrameDecoderBox()
    /// stdin 是否已关闭;仅在 `writeQueue` 上读写(关闭与写入同队列串行,避免对已关闭句柄写入触发 ObjC 异常)。
    nonisolated(unsafe) private var stdinClosed = false

    /// - Parameter launch: 启动配置
    public init(launch: ProcessLaunch) {
        self.launch = launch
    }

    /// 子进程 pid,启动后可用。
    public var processIdentifier: Int32 { process.processIdentifier }

    /// 传给语言服务器的环境:继承当前环境,但剔除应用调试开关与凭据类变量。
    static func sanitizedEnvironment(extra: [String: String]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment.filter { key, _ in
            !(key.hasPrefix("OMA_") || key.hasPrefix("ANTHROPIC_") || key.hasSuffix("_API_KEY") || key.hasSuffix("_TOKEN"))
        }
        for (key, value) in extra { env[key] = value }
        return env
    }

    public func start() throws -> AsyncStream<TransportEvent> {
        // 子进程提前退出后写管道会收到 SIGPIPE 直接杀死本进程,统一忽略,改由 write 返回 EPIPE
        signal(SIGPIPE, SIG_IGN)
        process.executableURL = URL(fileURLWithPath: launch.executable)
        process.arguments = launch.arguments
        process.environment = Self.sanitizedEnvironment(extra: launch.environment)
        if let cwd = launch.workingDirectory { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let (stream, continuation) = AsyncStream<TransportEvent>.makeStream(bufferingPolicy: .unbounded)
        stdoutPipe.fileHandleForReading.readabilityHandler = { [decoder] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            for body in decoder.push(data) { continuation.yield(.line(body)) }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            if let text = String(data: data, encoding: .utf8) { continuation.yield(.stderr(text)) }
        }
        let name = (launch.executable as NSString).lastPathComponent
        process.terminationHandler = { [stdoutPipe, stderrPipe, decoder] proc in
            ProcessRegistry.shared.unregister(pid: proc.processIdentifier)
            Log.lsp.info("语言服务器进程退出", ["server": name, "pid": "\(proc.processIdentifier)", "status": "\(proc.terminationStatus)"])
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            if let rest = try? stdoutPipe.fileHandleForReading.readToEnd(), !rest.isEmpty {
                for body in decoder.push(rest) { continuation.yield(.line(body)) }
            }
            continuation.yield(.closed(exitCode: proc.terminationStatus))
            continuation.finish()
        }
        do { try process.run() } catch {
            Log.lsp.error("语言服务器启动失败", error: error, ["executable": launch.executable])
            throw error
        }
        ProcessRegistry.shared.register(pid: process.processIdentifier, role: .lsp, label: name)
        Log.lsp.info("语言服务器已启动", ["server": name, "args": launch.arguments.joined(separator: " "), "cwd": launch.workingDirectory ?? "-", "pid": "\(process.processIdentifier)"])
        return stream
    }

    public func send(_ data: Data) {
        let frame = LSPFrameEncoder.encode(data)
        let handle = stdinPipe.fileHandleForWriting
        writeQueue.async { [self] in
            guard !stdinClosed else { return }
            do { try handle.write(contentsOf: frame) } catch {
                Log.lsp.warning("语言服务器写入失败", ["error": "\(error)"])
            }
        }
    }

    /// 停止传输:在写队列上关闭 stdin(排在已入队的写入之后),随后终止子进程;关闭后的 `send` 会被丢弃。
    public func stop() {
        let handle = stdinPipe.fileHandleForWriting
        writeQueue.async { [self] in
            guard !stdinClosed else { return }
            stdinClosed = true
            try? handle.close()
        }
        if process.isRunning { process.terminate() }
    }
}
