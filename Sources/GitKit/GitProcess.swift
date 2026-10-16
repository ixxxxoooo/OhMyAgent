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
        let elapsed = ContinuousClock.now - started
        let milliseconds = elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000
        let output = GitOutput(status: process.terminationStatus, stdout: outData, stderr: String(decoding: errData, as: UTF8.self))
        Log.git.debug("git 已执行", ["cmd": command, "status": "\(output.status)", "ms": "\(milliseconds)"])
        if timedOut { throw GitError.timedOut(command) }
        try Task.checkCancellation()
        return output
    }

    /// 在全局队列上读尽管道(阻塞读取不占用协作线程池)。
    private static func readAll(_ pipe: Pipe) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: (try? pipe.fileHandleForReading.readToEnd()) ?? Data())
            }
        }
    }
}
