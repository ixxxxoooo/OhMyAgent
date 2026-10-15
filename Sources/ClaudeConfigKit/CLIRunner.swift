// @author ygw
// 调用官方 `claude` CLI(插件、MCP 健康检查等"通道 C"操作)。带超时与输出收集。

import Foundation
import Synchronization

/// CLI 执行结果。
public struct CLIResult: Sendable, Equatable {
    public var exitCode: Int32
    public var standardOutput: String
    public var standardError: String
    public var timedOut: Bool

    public var succeeded: Bool { exitCode == 0 && !timedOut }

    /// 面向用户的失败说明。
    public var failureMessage: String {
        if timedOut { return "命令执行超时" }
        let text = standardError.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? (standardOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "命令退出码 \(exitCode)" : standardOutput) : text
    }
}

/// CLI 执行器。
public struct CLIRunner: Sendable {
    public var executable: String
    public var environment: [String: String]

    /// - Parameters:
    ///   - executable: `claude` 可执行文件路径
    ///   - environment: 子进程环境(通常取自登录 shell)
    public init(executable: String, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.executable = executable
        self.environment = environment
    }

    /// 执行命令。
    /// - Parameters:
    ///   - arguments: 参数
    ///   - directory: 工作目录
    ///   - timeout: 超时秒数,超时后先 SIGTERM 再 SIGKILL
    public func run(_ arguments: [String], in directory: URL? = nil, timeout: TimeInterval = 60) async -> CLIResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        let out = Mutex(Data()), err = Mutex(Data())
        outPipe.fileHandleForReading.readabilityHandler = { handle in let chunk = handle.availableData; if !chunk.isEmpty { out.withLock { $0.append(chunk) } } }
        errPipe.fileHandleForReading.readabilityHandler = { handle in let chunk = handle.availableData; if !chunk.isEmpty { err.withLock { $0.append(chunk) } } }
        let timedOut = Mutex(false)

        return await withCheckedContinuation { (continuation: CheckedContinuation<CLIResult, Never>) in
            process.terminationHandler = { finished in
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                let tailOut = outPipe.fileHandleForReading.readDataToEndOfFile()
                let tailErr = errPipe.fileHandleForReading.readDataToEndOfFile()
                let stdout = out.withLock { $0.append(tailOut); return String(decoding: $0, as: UTF8.self) }
                let stderr = err.withLock { $0.append(tailErr); return String(decoding: $0, as: UTF8.self) }
                continuation.resume(returning: CLIResult(exitCode: finished.terminationStatus, standardOutput: stdout, standardError: stderr, timedOut: timedOut.withLock { $0 }))
            }
            do {
                try process.run()
            } catch {
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                process.terminationHandler = nil
                continuation.resume(returning: CLIResult(exitCode: -1, standardOutput: "", standardError: error.localizedDescription, timedOut: false))
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard process.isRunning else { return }
                timedOut.withLock { $0 = true }
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
            }
        }
    }
}
