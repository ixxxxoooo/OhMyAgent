// @author ixxxxoooo
// 一次性运行 `claude` 子命令(如 `auth logout`、`auth status`),异步等待,不阻塞调用线程。

import Foundation

/// 子命令运行结果。
public struct CLIRunResult: Sendable, Equatable {
    public var status: Int32
    public var stdout: String
    public var stderr: String
}

/// 子命令运行错误。
public enum CLIRunError: Error, LocalizedError, Sendable {
    case launchFailed(String)
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .launchFailed(let reason): "无法启动 claude:\(reason)"
        case .timedOut: "claude 命令超时"
        }
    }
}

/// 子命令运行器。
public enum CLIRunner {
    /// 运行命令并收集输出。
    /// - Parameters:
    ///   - executable: 可执行文件绝对路径
    ///   - arguments: 参数
    ///   - environment: 叠加到当前进程环境的变量
    ///   - timeout: 超时秒数
    /// - Throws: `CLIRunError`
    public static func run(executable: String, arguments: [String], environment: [String: String] = [:], timeout: TimeInterval = 30) async throws -> CLIRunResult {
        guard FileManager.default.isExecutableFile(atPath: executable) else { throw CLIRunError.launchFailed("找不到可执行文件 \(executable)") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        let collected = OutputCollector()
        let timedOut = TimeoutFlag()
        out.fileHandleForReading.readabilityHandler = { handle in collected.appendOut(handle.availableData) }
        err.fileHandleForReading.readabilityHandler = { handle in collected.appendErr(handle.availableData) }
        let finished: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { proc in continuation.resume(returning: proc.terminationStatus) }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: CLIRunError.launchFailed(error.localizedDescription))
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if process.isRunning { timedOut.set(); process.terminate() } }
        }
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        collected.appendOut(out.fileHandleForReading.readDataToEndOfFile())
        collected.appendErr(err.fileHandleForReading.readDataToEndOfFile())
        if timedOut.value { throw CLIRunError.timedOut }
        let result = collected.snapshot()
        return CLIRunResult(status: finished, stdout: result.out, stderr: result.err)
    }
}

/// 线程安全的输出收集器。
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()

    func appendOut(_ data: Data) { lock.withLock { out.append(data) } }
    func appendErr(_ data: Data) { lock.withLock { err.append(data) } }
    func snapshot() -> (out: String, err: String) {
        lock.withLock { (String(decoding: out, as: UTF8.self), String(decoding: err, as: UTF8.self)) }
    }
}

/// 超时标记。
private final class TimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.withLock { flag = true } }
    var value: Bool { lock.withLock { flag } }
}
