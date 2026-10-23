// @author ixxxxoooo
// 传输抽象与 Stdio 实现。

import Darwin
import Foundation
import OMLog
import Synchronization

/// 传输层收到的事件。
public enum TransportEvent: Sendable {
    /// 收到一行完整数据
    case line(Data)
    /// 标准错误输出(日志)
    case stderr(String)
    /// 已解析的消息(仅进程内直连传输产生:跳过序列化与再解析;其余传输永远不会发出)
    case message(JSONRPCMessage)
    /// 传输关闭,附带退出码(若有)
    case closed(exitCode: Int32?)
}

/// ACP 传输抽象:可替换为 Stdio、HTTP、WebSocket 等。
public protocol ACPTransport: Sendable {
    /// 启动传输并返回事件流。
    func start() throws -> AsyncStream<TransportEvent>
    /// 发送一条已序列化的消息(不含换行,实现负责追加)。
    func send(_ data: Data)
    /// 停止传输。
    func stop()
    /// 发送一条尚未序列化的消息。进程内直连传输可直接投递给对端而省去序列化与解析;默认实现序列化后走 `send(_:)`。
    func send(message: JSONRPCMessage) throws
    /// 声明本端能直接接收 `.message` 事件(`ACPConnection` 启动时调用);默认空实现。
    func enableDirectMessages()
}

public extension ACPTransport {
    func send(message: JSONRPCMessage) throws { send(try message.serialized()) }
    func enableDirectMessages() {}
}

/// 子进程启动配置。
public struct ProcessLaunch: Sendable, Hashable {
    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]
    public var workingDirectory: String?

    public init(executable: String, arguments: [String] = [], environment: [String: String] = [:], workingDirectory: String? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
    }
}

/// 线程安全的行分帧器盒子(Mutex 不可复制,需用类包装后才能被闭包捕获)。
final class FramerBox: Sendable {
    private let state = Mutex(LineFramer())

    /// 喂入数据并返回完整行。
    func push(_ data: Data) -> [Data] {
        state.withLock { $0.push(data) }
    }
}

/// 基于子进程标准输入输出的传输,换行分隔 JSON。
public final class StdioTransport: ACPTransport, @unchecked Sendable {
    /// 子进程输出行的积压(生产:读管道回调;消费:`ACPConnection` 的读循环)。
    public static let backlog = StreamBacklog(name: "backlog.acpLines", warnDepth: 5000)
    private let launch: ProcessLaunch
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    /// 串行写队列,保证消息顺序且不阻塞调用方。
    private let writeQueue = DispatchQueue(label: "OhMyAgent.StdioTransport.write")
    /// stdin 的原始文件描述符,在 `init` 中捕获。所有写入均用 POSIX `write()`:
    /// 失败只返回 -1 并设置 errno,绝不抛出 Objective-C 异常,因此不会把异常抛过
    /// dispatch 队列边界导致进程 abort。
    private let stdinFileDescriptor: Int32
    /// stdin 是否已关闭;仅在 `writeQueue` 上读写(关闭与写入同队列串行,无锁竞争)。
    nonisolated(unsafe) private var stdinClosed = false
    private let framer = FramerBox()

    public init(launch: ProcessLaunch) {
        self.launch = launch
        // Pipe 创建后即持有有效的写端 fd;在此捕获原始 fd,此后无论 `FileHandle` 是否被 close,
        // fd 值本身仍可用于 POSIX write(失败会得到 EBADF/EPIPE 并被优雅处理,不会抛异常)。
        self.stdinFileDescriptor = stdinPipe.fileHandleForWriting.fileDescriptor
    }

    /// 子进程的 pid,启动后可用。
    public var processIdentifier: Int32 { process.processIdentifier }

    public func start() throws -> AsyncStream<TransportEvent> {
        // 子进程提前退出后写管道会收到 SIGPIPE 直接杀死本进程,统一忽略,改由 write 返回 EPIPE
        signal(SIGPIPE, SIG_IGN)
        process.executableURL = URL(fileURLWithPath: launch.executable)
        process.arguments = launch.arguments
        var env = ProcessInfo.processInfo.environment
        for (key, value) in launch.environment { env[key] = value }
        process.environment = env
        if let cwd = launch.workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        }
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let (stream, continuation) = AsyncStream<TransportEvent>.makeStream(bufferingPolicy: .unbounded)

        stdoutPipe.fileHandleForReading.readabilityHandler = { [framer] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            let lines = framer.push(data)
            StdioTransport.backlog.produced(lines.count)
            for line in lines { continuation.yield(.line(line)) }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            if let text = String(data: data, encoding: .utf8) {
                continuation.yield(.stderr(text))
            }
        }
        let launchDescription = "\((launch.executable as NSString).lastPathComponent) \(launch.arguments.joined(separator: " "))"
        process.terminationHandler = { [stdoutPipe, stderrPipe, framer] proc in
            ProcessRegistry.shared.unregister(pid: proc.processIdentifier)
            Log.agent.info("子进程退出", ["cmd": launchDescription, "pid": "\(proc.processIdentifier)", "status": "\(proc.terminationStatus)", "reason": proc.terminationReason == .exit ? "exit" : "signal"])
            // 读尽残余数据后再通知关闭,避免丢失最后几行
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            if let rest = try? stdoutPipe.fileHandleForReading.readToEnd(), !rest.isEmpty {
                let lines = framer.push(rest)
                for line in lines { continuation.yield(.line(line)) }
            }
            continuation.yield(.closed(exitCode: proc.terminationStatus))
            continuation.finish()
        }
        do { try process.run() } catch {
            Log.agent.error("子进程启动失败", error: error, ["executable": launch.executable, "args": launch.arguments.joined(separator: " ")])
            throw error
        }
        ProcessRegistry.shared.register(pid: process.processIdentifier, role: .agent, label: (launch.executable as NSString).lastPathComponent)
        Log.agent.info("子进程已启动", ["executable": launch.executable, "args": launch.arguments.joined(separator: " "), "cwd": launch.workingDirectory ?? "-", "pid": "\(process.processIdentifier)"])
        return stream
    }

    public func send(_ data: Data) {
        var framed = data
        framed.append(0x0A)
        let payload = framed
        writeQueue.async { [self] in
            guard !stdinClosed else { return }
            var offset = 0
            while offset < payload.count {
                let written = payload.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> Int in
                    guard let base = buffer.baseAddress else { return 0 }
                    return Darwin.write(stdinFileDescriptor, base.advanced(by: offset), payload.count - offset)
                }
                if written < 0 {
                    let err = errno
                    if err == EINTR { continue }
                    Log.agent.warning("写入子进程 stdin 失败,传输已关闭", ["fd": "\(stdinFileDescriptor)", "errno": "\(err)", "error": String(cString: strerror(err))])
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
            // 必须经 FileHandle 关闭:Pipe 释放时会再关一次同一 fd,若这里直接 close(fd) 就会双重关闭,
            // 而 fd 号可能已被其他会话复用,导致后续连接随机卡死。
            try? stdinPipe.fileHandleForWriting.close()
        }
        if process.isRunning {
            process.terminate()
        }
    }
}

/// 内存管道传输,用于单元测试:两端互连。
public final class LoopbackTransport: ACPTransport, @unchecked Sendable {
    private let continuation = Mutex<AsyncStream<TransportEvent>.Continuation?>(nil)
    private let peer = Mutex<LoopbackTransport?>(nil)
    /// 本端是否接受直连消息(由 `ACPConnection` 启动时开启)。
    private let acceptsMessages = Mutex<Bool>(false)

    public init() {}

    public func enableDirectMessages() { acceptsMessages.withLock { $0 = true } }

    /// 对端接受直连消息时原样投递(不序列化),否则退回行协议。
    public func send(message: JSONRPCMessage) throws {
        let other = peer.withLock { $0 }
        if let other, other.acceptsMessages.withLock({ $0 }) {
            other.continuation.withLock { $0 }?.yield(.message(message))
        } else {
            send(try message.serialized())
        }
    }

    /// 创建一对互相连接的传输。
    public static func makePair() -> (LoopbackTransport, LoopbackTransport) {
        let a = LoopbackTransport()
        let b = LoopbackTransport()
        a.peer.withLock { $0 = b }
        b.peer.withLock { $0 = a }
        return (a, b)
    }

    public func start() throws -> AsyncStream<TransportEvent> {
        let (stream, cont) = AsyncStream<TransportEvent>.makeStream(bufferingPolicy: .unbounded)
        continuation.withLock { $0 = cont }
        return stream
    }

    public func send(_ data: Data) {
        let other = peer.withLock { $0 }
        other?.continuation.withLock { $0 }?.yield(.line(data))
    }

    public func stop() {
        continuation.withLock { cont in
            cont?.yield(.closed(exitCode: 0))
            cont?.finish()
        }
        let other = peer.withLock { $0 }
        other?.continuation.withLock { cont in
            cont?.yield(.closed(exitCode: 0))
            cont?.finish()
        }
    }
}

/// 基于当前进程 stdin/stdout 的传输(Agent 侧):供自带的 ACP Agent 可执行文件使用。
public final class StdioServerTransport: ACPTransport, @unchecked Sendable {
    private let writeQueue = DispatchQueue(label: "OhMyAgent.StdioServerTransport.write")

    public init() {}

    public func start() throws -> AsyncStream<TransportEvent> {
        let (stream, continuation) = AsyncStream<TransportEvent>.makeStream(bufferingPolicy: .unbounded)
        let thread = Thread {
            var framer = LineFramer()
            let input = FileHandle.standardInput
            while true {
                let data = input.availableData
                if data.isEmpty { break }
                for line in framer.push(data) { continuation.yield(.line(line)) }
            }
            continuation.yield(.closed(exitCode: 0))
            continuation.finish()
        }
        thread.start()
        return stream
    }

    public func send(_ data: Data) {
        var payload = data
        payload.append(0x0A)
        let framed = payload
        writeQueue.async {
            var offset = 0
            while offset < framed.count {
                let written = framed.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> Int in
                    guard let base = buffer.baseAddress else { return 0 }
                    return Darwin.write(STDOUT_FILENO, base.advanced(by: offset), framed.count - offset)
                }
                if written < 0 {
                    if errno == EINTR { continue }
                    Log.agent.warning("写入标准输出失败", ["errno": "\(errno)", "error": String(cString: strerror(errno))])
                    break
                }
                offset += written
            }
        }
    }

    public func stop() {}
}
