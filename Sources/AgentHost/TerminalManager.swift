// @author ixxxxoooo
// 终端管理器:实现 ACP `terminal/*` 反向请求。使用管道合并 stdout/stderr(而非 PTY),
// 因为 ACP 终端用于捕获命令输出;输出按字节上限保留尾部,并在 UTF-8 边界截断。

import ACPKit
import Foundation
import OMLog
import Synchronization

/// 单个终端进程。
final class ManagedTerminal: Sendable {
    private struct State {
        var buffer = Data()
        var truncated = false
        var exitCode: Int?
        var signal: String?
        var exited = false
        var waiters: [CheckedContinuation<Void, Never>] = []
        var released = false
    }

    let id: String
    let command: String
    let limit: Int
    private let process: Process
    private let state = Mutex(State())

    init(id: String, command: String, args: [String], environment: [String: String], cwd: String?, limit: Int) throws {
        self.id = id
        self.command = ([command] + args).joined(separator: " ")
        self.limit = max(1024, limit)
        let process = Process()
        // 通过 env 解析命令名,使 PATH 中的命令(如 npm、git)可直接使用
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [command] + args
        process.environment = environment
        if let cwd, !cwd.isEmpty { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        self.process = process

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self?.append(data)
        }
        process.terminationHandler = { [weak self] proc in
            // 读尽管道中剩余数据后再标记退出
            if let remaining = try? pipe.fileHandleForReading.readToEnd(), !remaining.isEmpty {
                self?.append(remaining)
            }
            pipe.fileHandleForReading.readabilityHandler = nil
            Log.terminal.info("终端命令已退出", ["id": id, "status": "\(proc.terminationStatus)", "reason": proc.terminationReason == .exit ? "exit" : "signal"])
            self?.markExited(code: proc.terminationReason == .exit ? Int(proc.terminationStatus) : nil,
                             signal: proc.terminationReason == .uncaughtSignal ? "SIG\(proc.terminationStatus)" : nil)
        }
        do { try process.run() } catch {
            Log.terminal.error("终端命令启动失败", error: error, ["command": command, "cwd": cwd ?? "-"])
            throw error
        }
        Log.terminal.info("终端命令已启动", ["id": id, "command": command, "args": args.joined(separator: " "), "cwd": cwd ?? "-", "pid": "\(process.processIdentifier)"])
    }

    private func append(_ data: Data) {
        state.withLock { state in
            state.buffer.append(data)
            if state.buffer.count > limit {
                state.buffer.removeFirst(state.buffer.count - limit)
                state.truncated = true
            }
        }
    }

    private func markExited(code: Int?, signal: String?) {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.exited = true
            state.exitCode = code
            state.signal = signal
            let waiters = state.waiters
            state.waiters = []
            return waiters
        }
        for waiter in waiters { waiter.resume() }
    }

    /// 当前输出快照。
    func snapshot() -> TerminalOutputSnapshot {
        state.withLock { state in
            var data = state.buffer
            // 截断后丢弃开头不完整的 UTF-8 续字节
            if state.truncated {
                while let first = data.first, first & 0xC0 == 0x80 { data.removeFirst() }
            }
            return TerminalOutputSnapshot(output: String(decoding: data, as: UTF8.self), truncated: state.truncated,
                                          exitCode: state.exitCode, signal: state.signal)
        }
    }

    var isRunning: Bool { state.withLock { !$0.exited } }

    /// 等待进程退出。
    func waitForExit() async {
        await withCheckedContinuation { continuation in
            let resumeNow = state.withLock { state -> Bool in
                if state.exited { return true }
                state.waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    /// 终止进程:先 SIGTERM,2 秒后仍未退出则 SIGKILL。
    func kill() {
        guard isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        Task.detached { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            if self?.isRunning == true { Foundation.kill(pid, SIGKILL) }
        }
    }
}

/// 终端创建通知(供 UI 建立终端视图)。
public struct TerminalCreated: Sendable {
    public var id: String
    public var command: String
}

/// 终端管理器。
public actor TerminalManager {
    private var terminals: [String: ManagedTerminal] = [:]
    private let environmentProvider: @Sendable () -> [String: String]
    private let workspace: String
    private let onCreated: (@Sendable (TerminalCreated) -> Void)?

    /// 创建管理器。
    /// - Parameters:
    ///   - workspace: 默认工作目录
    ///   - environment: 基础环境(登录 shell 环境)
    ///   - onCreated: 新终端创建时的回调
    public init(workspace: String, environment: @escaping @Sendable () -> [String: String] = { ProcessInfo.processInfo.environment },
                onCreated: (@Sendable (TerminalCreated) -> Void)? = nil) {
        self.workspace = workspace
        self.environmentProvider = environment
        self.onCreated = onCreated
    }

    /// 创建终端并开始执行。
    public func create(command: String, args: [String], env: [String: String], cwd: String?, outputByteLimit: Int?) throws -> String {
        guard !command.isEmpty else { throw JSONRPCError(code: JSONRPCError.invalidParams, message: "command 不能为空") }
        var environment = environmentProvider()
        for (key, value) in env { environment[key] = value }
        let id = "term-\(UUID().uuidString.prefix(8))"
        let terminal = try ManagedTerminal(id: id, command: command, args: args, environment: environment,
                                           cwd: cwd ?? workspace, limit: outputByteLimit ?? 1_048_576)
        terminals[id] = terminal
        onCreated?(TerminalCreated(id: id, command: terminal.command))
        return id
    }

    /// 读取输出快照。
    public func output(_ id: String) throws -> TerminalOutputSnapshot {
        try find(id).snapshot()
    }

    /// 等待退出并返回最终快照。
    public func waitForExit(_ id: String) async throws -> TerminalOutputSnapshot {
        let terminal = try find(id)
        await terminal.waitForExit()
        return terminal.snapshot()
    }

    /// 终止进程(终端保留,仍可读取输出)。
    public func kill(_ id: String) throws {
        try find(id).kill()
    }

    /// 释放终端:终止进程并移除。
    public func release(_ id: String) throws {
        let terminal = try find(id)
        terminal.kill()
        terminals[id] = nil
    }

    /// 终止并清理全部终端(窗口关闭时)。
    public func shutdown() {
        for terminal in terminals.values { terminal.kill() }
        terminals.removeAll()
    }

    /// 非抛出的快照读取(UI 轮询用)。
    public func peek(_ id: String) -> TerminalOutputSnapshot? {
        terminals[id]?.snapshot()
    }

    private func find(_ id: String) throws -> ManagedTerminal {
        guard let terminal = terminals[id] else {
            throw JSONRPCError(code: JSONRPCError.invalidParams, message: "未知终端: \(id)")
        }
        return terminal
    }
}
