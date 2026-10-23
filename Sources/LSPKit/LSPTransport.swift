// @author ixxxxoooo
// LSP 传输:语言服务器子进程的 stdio(Content-Length 分帧),以及内存分帧回环(测试用)。
// 两者都实现 ACPKit 的 `ACPTransport`:每个完整 JSON 正文作为一行事件上抛,从而复用 `ACPConnection` 的 JSON-RPC 逻辑。

import ACPKit
import Darwin
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
    /// 串行写队列,保证消息顺序且不阻塞调用方。
    private let writeQueue = DispatchQueue(label: "OhMyAgent.LSPStdioTransport.write")
    /// stdin 的原始文件描述符,在 `init` 中捕获。所有写入均用 POSIX `write()`:
    /// 失败只返回 -1 并设置 errno,绝不抛出 Objective-C 异常,因此不会把异常抛过
    /// dispatch 队列边界导致进程 abort(本模块曾因 `NSFileHandle.write` 抛出的 ObjC 异常
    /// 在子进程退出/管道关闭后写入而崩溃)。
    private let stdinFileDescriptor: Int32
    /// stdin 是否已关闭;仅在 `writeQueue` 上读写(关闭与写入同队列串行,无锁竞争)。
    nonisolated(unsafe) private var stdinClosed = false
    private let decoder = FrameDecoderBox()

    /// - Parameter launch: 启动配置
    public init(launch: ProcessLaunch) {
        self.launch = launch
        // Pipe 创建后即持有有效的写端 fd;在此捕获原始 fd,此后无论 `FileHandle` 是否被 close,
        // fd 值本身仍可用于 POSIX write(失败会得到 EBADF/EPIPE 并被优雅处理,不会抛异常)。
        self.stdinFileDescriptor = stdinPipe.fileHandleForWriting.fileDescriptor
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
        writeQueue.async { [self] in
            guard !stdinClosed else { return }
            var offset = 0
            while offset < frame.count {
                let written = frame.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> Int in
                    guard let base = buffer.baseAddress else { return 0 }
                    return Darwin.write(stdinFileDescriptor, base.advanced(by: offset), frame.count - offset)
                }
                if written < 0 {
                    let err = errno
                    if err == EINTR { continue }
                    Log.lsp.warning("写入语言服务器 stdin 失败,传输已关闭", ["fd": "\(stdinFileDescriptor)", "errno": "\(err)", "error": String(cString: strerror(err))])
                    // 不抛异常:Objective-C 异常穿过 dispatch 队列会导致 abort。
                    stdinClosed = true
                    break
                }
                offset += written
            }
        }
    }

    /// 停止传输:在写队列上关闭 stdin(排在已入队的写入之后),随后终止子进程;关闭后的 `send` 会被丢弃。
    public func stop() {
        writeQueue.async { [self] in
            guard !stdinClosed else { return }
            stdinClosed = true
            // 经 FileHandle 关闭,避免与 Pipe 释放时的关闭形成 fd 双重关闭(fd 号可能已被其他连接复用)
            try? stdinPipe.fileHandleForWriting.close()
        }
        if process.isRunning { process.terminate() }
    }
}
