// @author ixxxxoooo
// 传输抽象与 Stdio 实现。

import Foundation
import OMLog
import Synchronization

/// 传输层收到的事件。
public enum TransportEvent: Sendable {
    /// 收到一行完整数据
    case line(Data)
    /// 标准错误输出(日志)
    case stderr(String)
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
    private let launch: ProcessLaunch
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    /// 串行写队列,保证消息顺序且不阻塞调用方。
    private let writeQueue = DispatchQueue(label: "OhMyAgent.StdioTransport.write")
    private let framer = FramerBox()

    public init(launch: ProcessLaunch) {
        self.launch = launch
    }

    /// 子进程的 pid,启动后可用。
    public var processIdentifier: Int32 { process.processIdentifier }

    public func start() throws -> AsyncStream<TransportEvent> {
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
        let handle = stdinPipe.fileHandleForWriting
        writeQueue.async {
            try? handle.write(contentsOf: payload)
        }
    }

    public func stop() {
        stdinPipe.fileHandleForWriting.closeFile()
        if process.isRunning {
            process.terminate()
        }
    }
}

/// 内存管道传输,用于单元测试:两端互连。
public final class LoopbackTransport: ACPTransport, @unchecked Sendable {
    private let continuation = Mutex<AsyncStream<TransportEvent>.Continuation?>(nil)
    private let peer = Mutex<LoopbackTransport?>(nil)

    public init() {}

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
        writeQueue.async { FileHandle.standardOutput.write(framed) }
    }

    public func stop() {}
}
