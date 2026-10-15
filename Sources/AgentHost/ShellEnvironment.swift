// @author ygw
// 解析用户登录 shell 的环境变量。GUI 应用不会继承终端 PATH,需要主动取得。

import Foundation

/// 登录 shell 环境解析器。
public enum ShellEnvironment {
    /// 解析登录交互 shell 的环境变量(包含 nvm、Homebrew 等对 PATH 的修改)。
    /// 该调用会启动一个 shell 进程,应在后台调用并缓存结果。
    /// - Parameter timeout: 超时秒数,超时返回当前进程环境
    /// - Returns: 环境变量字典
    public static func resolve(timeout: TimeInterval = 5) async -> [String: String] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: resolveBlocking(timeout: timeout))
            }
        }
    }

    /// 同步版本,仅供后台线程与脚本使用。
    static func resolveBlocking(timeout: TimeInterval) -> [String: String] {
        let fallback = ProcessInfo.processInfo.environment
        let shell = fallback["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        // -i 让 .zshrc 生效(nvm 通常配置于此),标记用于剥离 shell 启动噪声
        process.arguments = ["-ilc", "printf '__OMA_ENV_START__'; env -0; printf '__OMA_ENV_END__'"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return fallback
        }
        let deadline = DispatchTime.now() + timeout
        let group = DispatchGroup()
        group.enter()
        nonisolated(unsafe) var collected = Data()
        DispatchQueue.global().async {
            collected = (try? stdout.fileHandleForReading.readToEnd()) ?? Data()
            group.leave()
        }
        if group.wait(timeout: deadline) == .timedOut {
            process.terminate()
            return fallback
        }
        return parse(collected) ?? fallback
    }

    /// 解析带标记的 `env -0` 输出。
    /// - Parameter data: shell 的原始输出
    /// - Returns: 环境变量字典,格式不符返回 nil
    static func parse(_ data: Data) -> [String: String]? {
        let text = String(decoding: data, as: UTF8.self)
        guard let start = text.range(of: "__OMA_ENV_START__"),
              let end = text.range(of: "__OMA_ENV_END__", range: start.upperBound..<text.endIndex) else {
            return nil
        }
        let body = text[start.upperBound..<end.lowerBound]
        var result: [String: String] = [:]
        for entry in body.split(separator: "\0") {
            guard let eq = entry.firstIndex(of: "=") else { continue }
            let key = String(entry[entry.startIndex..<eq])
            guard !key.isEmpty else { continue }
            result[key] = String(entry[entry.index(after: eq)...])
        }
        return result.isEmpty ? nil : result
    }
}
