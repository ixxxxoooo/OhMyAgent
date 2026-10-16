// @author ixxxxoooo
// ACP 适配器自动安装:应用包未内置(或被删除)时,用本机 npm 把 claude-agent-acp 装到
// ~/Library/Application Support/OhMyAgent/acp,用户无需手动运行任何脚本。

import Foundation
import OMLog

/// 适配器安装失败的原因。
public enum AdapterInstallError: Error, LocalizedError, Sendable {
    case npmNotFound
    case commandFailed(status: Int32, output: String)
    case entryMissing

    public var errorDescription: String? {
        switch self {
        case .npmNotFound:
            return String(localized: "未找到 npm,无法自动安装 claude-agent-acp 适配器。请安装 Node.js 22+(自带 npm),或在设置 → 高级中指定适配器路径。")
        case .commandFailed(let status, let output):
            let tail = output.split(separator: "\n").suffix(3).joined(separator: " ")
            return String(localized: "自动安装 claude-agent-acp 适配器失败(退出码 \(Int(status))):\(tail)。请检查网络后点击「重试」,或在设置 → 高级中指定适配器路径。")
        case .entryMissing:
            return String(localized: "适配器安装完成但未找到入口文件,请点击「重试」或在设置 → 高级中指定路径。")
        }
    }
}

/// 适配器安装器:同一时间只会有一个安装任务,并发调用共享结果。
public actor AdapterInstaller {
    public static let shared = AdapterInstaller()

    /// 固定安装的适配器版本(与 `Vendor/acp/package.json` 保持一致)
    public static let version = "0.91.0"
    /// 适配器包名
    public static let packageName = "@agentclientprotocol/claude-agent-acp"

    private var inflight: Task<String, Error>?

    private init() {}

    /// 默认安装目录:`~/Library/Application Support/OhMyAgent/acp`。
    public nonisolated static var defaultPrefix: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OhMyAgent", isDirectory: true)
            .appendingPathComponent("acp", isDirectory: true)
    }

    /// 适配器入口脚本相对安装目录的路径。
    public nonisolated static let entryRelativePath = "node_modules/\(packageName)/dist/index.js"

    /// 构造 `npm install` 参数(纯函数,便于测试)。
    /// - Parameter prefix: 安装目录
    /// - Returns: npm 参数数组
    public nonisolated static func installArguments(prefix: String) -> [String] {
        // --omit=optional:跳过 Agent SDK 的平台原生二进制(约 240MB),运行时使用用户本机的 claude
        ["install", "--prefix", prefix, "--no-audit", "--no-fund", "--ignore-scripts", "--omit=optional", "\(packageName)@\(version)"]
    }

    /// 在 node 所在目录与 PATH 中查找 npm。
    /// - Parameters:
    ///   - nodePath: node 可执行文件
    ///   - environment: 登录 shell 环境
    /// - Returns: npm 路径;找不到为 nil
    public nonisolated static func locateNPM(nodePath: String, environment: [String: String]) -> String? {
        let fm = FileManager.default
        var candidates = [((nodePath as NSString).deletingLastPathComponent as NSString).appendingPathComponent("npm")]
        candidates += (environment["PATH"] ?? "").split(separator: ":").map { "\($0)/npm" }
        candidates += ["/opt/homebrew/bin/npm", "/usr/local/bin/npm"]
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }

    /// 安装适配器(幂等:入口已存在则直接返回)。
    /// - Parameters:
    ///   - nodePath: 已定位的 node
    ///   - environment: 子进程环境(需包含 PATH)
    ///   - prefix: 安装目录,默认 Application Support
    /// - Returns: 适配器入口脚本绝对路径
    public func install(nodePath: String, environment: [String: String], prefix: URL = AdapterInstaller.defaultPrefix) async throws -> String {
        let entry = prefix.appendingPathComponent(Self.entryRelativePath).path
        if FileManager.default.isReadableFile(atPath: entry) { return entry }
        if let inflight { return try await inflight.value }
        let task = Task.detached(priority: .userInitiated) { () -> String in
            try Self.runInstall(nodePath: nodePath, environment: environment, prefix: prefix)
        }
        inflight = task
        defer { inflight = nil }
        return try await task.value
    }

    /// 同步执行 npm 安装(在后台线程调用)。
    private nonisolated static func runInstall(nodePath: String, environment: [String: String], prefix: URL) throws -> String {
        let log = Log.agent
        guard let npm = locateNPM(nodePath: nodePath, environment: environment) else { throw AdapterInstallError.npmNotFound }
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        let start = ContinuousClock.now
        log.info("开始自动安装适配器", ["npm": npm, "prefix": prefix.path, "version": version])

        let process = Process()
        process.executableURL = URL(fileURLWithPath: npm)
        process.arguments = installArguments(prefix: prefix.path)
        var env = environment
        // npm 是 node 脚本:确保 node 所在目录在 PATH 最前面
        let nodeDir = (nodePath as NSString).deletingLastPathComponent
        env["PATH"] = nodeDir + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch {
            log.error("启动 npm 失败", error: error)
            throw AdapterInstallError.commandFailed(status: -1, output: error.localizedDescription)
        }
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        let ms = "\(OMLogger.milliseconds(since: start))"
        guard process.terminationStatus == 0 else {
            log.error("自动安装适配器失败", ["status": "\(process.terminationStatus)", "ms": ms, "tail": String(output.suffix(300))])
            throw AdapterInstallError.commandFailed(status: process.terminationStatus, output: output)
        }
        let entry = prefix.appendingPathComponent(entryRelativePath).path
        guard FileManager.default.isReadableFile(atPath: entry) else { throw AdapterInstallError.entryMissing }
        log.info("适配器安装完成", ["entry": entry, "ms": ms])
        return entry
    }
}
