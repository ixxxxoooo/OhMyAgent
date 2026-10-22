// @author ixxxxoooo
// git 子进程执行器:在后台异步运行 /usr/bin/git,收集 stdout/stderr,支持超时与协作式取消。
// 不经过 shell,参数以数组传递,杜绝命令注入。

import Foundation
import OMLog
import Synchronization

/// 一次 git 调用的结果。
struct GitOutput: Sendable {
    var status: Int32
    var stdout: Data
    var stderr: String

    var text: String { String(decoding: stdout, as: UTF8.self) }
}

/// 进程退出信号:可在任意任务里等待,且不会因任务取消而提前返回
/// (提前返回时读取 `terminationReason` 会抛出 Objective-C 异常)。
private final class ExitGate: Sendable {
    private struct State {
        var done = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    func signal() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.done = true
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters { waiter.resume() }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let finished = state.withLock { state -> Bool in
                if state.done { return true }
                state.waiters.append(continuation)
                return false
            }
            if finished { continuation.resume() }
        }
    }
}

enum GitProcess {
    /// 定位 git 可执行文件:优先 `/usr/bin/git`(Xcode CLT 垫片),其次 Homebrew。
    static func executable() -> String {
        for candidate in ["/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git"]
        where FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        return "/usr/bin/git"
    }

    /// 子进程环境:禁用交互提示与分页,固定英文输出便于解析,避免不必要的仓库锁。
    static func environment() -> [String: String] {
        // 仓库定位类变量必须剔除:从 git 钩子启动的进程会继承它们,导致命令落到错误的仓库
        let repositoryVariables: Set<String> = ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR", "GIT_PREFIX", "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_NAMESPACE"]
        var env = ProcessInfo.processInfo.environment.filter { key, _ in
            !key.hasPrefix("OMA_") && !key.hasPrefix("ANTHROPIC_") && !repositoryVariables.contains(key)
        }
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_PAGER"] = "cat"
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env["LC_ALL"] = "C"
        env["GIT_EDITOR"] = "true"
        if env["GIT_SSH_COMMAND"] == nil { env["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes" }
        return env
    }

    /// 运行 git。
    /// - Parameters:
    ///   - arguments: 参数(不含 `git` 本身)
    ///   - directory: 工作目录
    ///   - input: 写入 stdin 的数据
    ///   - timeout: 超时秒数,超时后终止进程
    ///   - lockFree: 为 false 时允许 git 写入可选锁(如 status 刷新索引)
    /// - Returns: 输出;非零退出码也会返回,由调用方决定是否抛错
    static func run(_ arguments: [String], in directory: URL, input: Data? = nil, timeout: TimeInterval = 60, lockFree: Bool = true) async throws -> GitOutput {
        let started = ContinuousClock.now
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable())
        process.arguments = arguments
        process.currentDirectoryURL = directory
        var env = environment()
        if !lockFree { env["GIT_OPTIONAL_LOCKS"] = "1" }
        process.environment = env
        let outPipe = Pipe(), errPipe = Pipe(), inPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = input == nil ? FileHandle.nullDevice : inPipe

        // 退出通知用 terminationHandler(不用 waitUntilExit:它在后台线程里依赖 RunLoop,可能永远不返回)
        let gate = ExitGate()
        process.terminationHandler = { _ in gate.signal() }
        do { try process.run() } catch {
            Log.git.error("git 启动失败", ["args": arguments.first ?? "", "error": "\(error)"])
            throw GitError.launchFailed("\(error)")
        }
        let command = arguments.first ?? ""
        if let input {
            // 写入放到后台队列,避免大输入与输出管道互相阻塞
            DispatchQueue.global().async {
                try? inPipe.fileHandleForWriting.write(contentsOf: input)
                try? inPipe.fileHandleForWriting.close()
            }
        }
        let watchdog = Task {
            try await Task.sleep(for: .seconds(timeout))
            if process.isRunning { process.terminate() }
        }
        let (outData, errData): (Data, Data) = await withTaskCancellationHandler {
            async let stdout = readAll(outPipe)
            async let stderr = readAll(errPipe)
            let pair = await (stdout, stderr)
            await gate.wait()
            return pair
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
        let timedOut = process.terminationReason == .uncaughtSignal && process.terminationStatus == SIGTERM && !Task.isCancelled
        watchdog.cancel()
        let micros = OMLogger.microseconds(since: started)
        let milliseconds = micros / 1000
        PerfStats.shared.record(name: "git 命令", micros: micros)
        let output = GitOutput(status: process.terminationStatus, stdout: outData, stderr: String(decoding: errData, as: UTF8.self))
        let fields = ["cmd": command, "status": "\(output.status)", "ms": "\(milliseconds)", "outBytes": "\(outData.count)"]
        if milliseconds >= 500 { Log.git.warning("git 命令较慢", fields) } else { Log.git.debug("git 已执行", fields) }
        if timedOut { throw GitError.timedOut(command) }
        try Task.checkCancellation()
        return output
    }

    /// 读尽管道:用 `readabilityHandler` 事件驱动,不占用任何线程阻塞等待
    /// (原先每个 git 进程占两个全局队列线程做阻塞读取,并发多个 git 时会耗尽线程)。
    private static func readAll(_ pipe: Pipe) async -> Data {
        let handle = pipe.fileHandleForReading
        let box = PipeBuffer()
        return await withCheckedContinuation { continuation in
            handle.readabilityHandler = { readable in
                let chunk = readable.availableData
                if chunk.isEmpty {
                    // EOF:摘掉处理器并交付(只会走到一次)
                    readable.readabilityHandler = nil
                    continuation.resume(returning: box.take())
                } else {
                    box.append(chunk)
                }
            }
        }
    }
}

/// 管道读取缓冲(处理器在私有队列上串行调用,锁只为满足 Sendable)。
private final class PipeBuffer: Sendable {
    private let data = Mutex(Data())

    func append(_ chunk: Data) { data.withLock { $0.append(chunk) } }

    func take() -> Data { data.withLock { current in
        defer { current = Data() }
        return current
    } }
}

/// 仓库级 git 调度:同一仓库同时最多 `limit` 个 git 进程(超出的排队,可取消);
/// 相同的只读命令并发时合并为一次执行(多个面板同时刷新同一份 status/log 时只跑一个进程)。
actor GitGate {
    static let shared = GitGate()

    /// 单仓库并发上限
    let limit: Int
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }
    private var running: [String: Int] = [:]
    private var waiters: [String: [Waiter]] = [:]
    private var inflight: [String: Task<GitOutput, Error>] = [:]
    private var epochs: [String: Int] = [:]
    /// 合并执行的累计次数(诊断/测试用)
    private(set) var mergedCount = 0

    init(limit: Int = 2) { self.limit = max(limit, 1) }

    /// 当前仓库正在运行的进程数(测试用)。
    func runningCount(root: String) -> Int { running[root] ?? 0 }

    /// 在闸门内执行。
    /// - Parameters:
    ///   - root: 仓库根路径(闸门按它分组)
    ///   - dedupeKey: 非 nil 时,同键的并发调用共享同一次执行(只用于只读命令)
    ///   - work: 实际执行
    func run(root: String, dedupeKey: String?, _ work: @escaping @Sendable () async throws -> GitOutput) async throws -> GitOutput {
        guard let dedupeKey else {
            // 写命令:前后各推进一次仓库「纪元」,在它之前开始的只读执行不会再被后来的读取合并(避免读到写之前的旧状态)
            epochs[root, default: 0] += 1
            defer { epochs[root, default: 0] += 1 }
            return try await gated(root: root, work)
        }
        let key = dedupeKey + "\u{2}\(epochs[root] ?? 0)"
        if let existing = inflight[key] {
            mergedCount += 1
            return try await existing.value
        }
        let task = Task<GitOutput, Error> { [self] in try await gated(root: root, work) }
        inflight[key] = task
        defer { inflight[key] = nil }
        return try await task.value
    }

    private func gated(root: String, _ work: @Sendable () async throws -> GitOutput) async throws -> GitOutput {
        try await acquire(root: root)
        defer { release(root: root) }
        return try await work()
    }

    private func acquire(root: String) async throws {
        if (running[root] ?? 0) < limit {
            running[root, default: 0] += 1
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                waiters[root, default: []].append(Waiter(id: id, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(root: root, id: id) }
        }
    }

    private func cancelWaiter(root: String, id: UUID) {
        guard let index = waiters[root]?.firstIndex(where: { $0.id == id }), let waiter = waiters[root]?.remove(at: index) else { return }
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func release(root: String) {
        if var queue = waiters[root], !queue.isEmpty {
            // 名额直接移交给队首,运行数不变
            let next = queue.removeFirst()
            waiters[root] = queue.isEmpty ? nil : queue
            next.continuation.resume()
        } else {
            let remaining = (running[root] ?? 1) - 1
            running[root] = remaining > 0 ? remaining : nil
        }
    }
}
