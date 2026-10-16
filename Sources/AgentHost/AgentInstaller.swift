// @author ixxxxoooo
// Agent 一键安装:按 ACP Registry 的二进制分发(binary distribution)下载、校验、解压并原子安装官方发行包。
// 目前用于 Google Antigravity(`agy_acp_server`):只允许从官方域名下载,用户点击后才发起网络请求。
//
// 安装目录:`~/Library/Application Support/OhMyAgent/agents/<id>/<version>/`,清单 `agents/<id>/manifest.json`。
// 安全:HTTPS + 域名白名单、解压后校验符号链接不越界、可执行路径不得跳出安装目录、先解压到暂存目录再原子替换。

import Foundation
import OMLog

// MARK: - 注册表模型

/// ACP Registry 里某个平台的二进制分发信息。
public struct RegistryBinary: Sendable, Equatable {
    /// 压缩包下载地址
    public var archive: String
    /// 压缩包内的可执行文件相对路径(如 `./agy_acp_server.par`)
    public var cmd: String
    /// 启动参数
    public var args: [String]

    public init(archive: String, cmd: String, args: [String] = []) {
        self.archive = archive
        self.cmd = cmd
        self.args = args
    }
}

/// ACP Registry 里的一个 Agent 条目(只关心二进制分发)。
public struct RegistryAgent: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var version: String
    public var summary: String?
    public var website: String?
    /// 平台 → 二进制分发(如 `darwin-aarch64`);没有二进制分发的 Agent 为空
    public var binary: [String: RegistryBinary]

    public init(id: String, name: String, version: String, summary: String? = nil, website: String? = nil, binary: [String: RegistryBinary] = [:]) {
        self.id = id
        self.name = name
        self.version = version
        self.summary = summary
        self.website = website
        self.binary = binary
    }

    /// 离线/注册表不可达时的内置回退:Google Antigravity ACP Server 1.4.0(与官方注册表一致)。
    public static let antigravityFallback = RegistryAgent(
        id: "antigravity-acp", name: "Google Antigravity", version: "1.4.0",
        summary: "Google’s AI coding agent", website: "https://antigravity.google/docs/ide/extensions",
        binary: [
            "darwin-aarch64": RegistryBinary(archive: "https://dl.google.com/agy-extensions/releases/macos/agy-acp-server-1.4.0-darwin-arm64.zip", cmd: "./agy_acp_server.par"),
            "darwin-x86_64": RegistryBinary(archive: "https://dl.google.com/agy-extensions/releases/macos/agy-acp-server-1.4.0-darwin-x86_64.zip", cmd: "./agy_acp_server.par"),
        ]
    )
}

/// ACP Registry 解析与平台判定。
public enum ACPRegistry {
    /// 官方注册表地址。
    public static let url = URL(string: "https://cdn.agentclientprotocol.com/registry/v1/latest/registry.json")!
    /// 允许拉取注册表的主机。
    public static let allowedHosts: Set<String> = ["cdn.agentclientprotocol.com"]

    /// 当前平台标识(与注册表键一致)。
    public static var currentPlatform: String {
        #if arch(arm64)
        "darwin-aarch64"
        #else
        "darwin-x86_64"
        #endif
    }

    private struct Document: Decodable {
        var agents: [Entry]
        struct Entry: Decodable {
            var id: String
            var name: String?
            var version: String?
            var description: String?
            var website: String?
            var distribution: Distribution?
        }
        struct Distribution: Decodable {
            var binary: [String: Binary]?
        }
        struct Binary: Decodable {
            var archive: String?
            var cmd: String?
            var args: [String]?
        }
    }

    /// 解析注册表 JSON;缺字段的条目会被跳过或以空二进制分发保留。
    /// - Parameter data: registry.json 内容
    /// - Returns: Agent 列表
    public static func parse(_ data: Data) throws -> [RegistryAgent] {
        let document = try JSONDecoder().decode(Document.self, from: data)
        return document.agents.map { entry in
            var binary: [String: RegistryBinary] = [:]
            for (platform, item) in entry.distribution?.binary ?? [:] {
                if let archive = item.archive, let cmd = item.cmd { binary[platform] = RegistryBinary(archive: archive, cmd: cmd, args: item.args ?? []) }
            }
            return RegistryAgent(id: entry.id, name: entry.name ?? entry.id, version: entry.version ?? "0", summary: entry.description, website: entry.website, binary: binary)
        }
    }

    /// 拉取官方注册表(限定域名,15 秒超时)。
    /// - Returns: Agent 列表
    public static func fetch(session: URLSession = .shared) async throws -> [RegistryAgent] {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw AgentInstallError.downloadFailed(String(localized: "注册表返回异常状态")) }
        return try parse(data)
    }
}

// MARK: - 错误与进度

/// 安装失败原因。
public enum AgentInstallError: Error, LocalizedError, Sendable, Equatable {
    case unsupportedPlatform(String)
    case untrustedSource(String)
    case downloadFailed(String)
    case corruptArchive
    case extractFailed(String)
    case unsafeArchive
    case missingExecutable(String)
    case invalidIdentifier(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedPlatform(let platform): return String(localized: "官方没有提供适用于 \(platform) 的发行包。")
        case .untrustedSource(let host): return String(localized: "下载地址「\(host)」不在官方白名单内,已拒绝。")
        case .downloadFailed(let reason): return String(localized: "下载失败:\(reason)")
        case .corruptArchive: return String(localized: "下载的压缩包为空或已损坏,请重试。")
        case .extractFailed(let reason): return String(localized: "解压失败:\(reason)")
        case .unsafeArchive: return String(localized: "压缩包包含越界的链接,已拒绝安装。")
        case .missingExecutable(let path): return String(localized: "压缩包里没有找到可执行文件 \(path)。")
        case .invalidIdentifier(let id): return String(localized: "非法的 Agent 标识:\(id)")
        }
    }
}

/// 安装进度。
public enum AgentInstallProgress: Sendable, Equatable {
    /// 下载中(0...1;总大小未知时为 nil)
    case downloading(Double?)
    case extracting
    case finalizing
}

/// 已安装的 Agent。
public struct InstalledAgent: Sendable, Equatable, Codable {
    public var id: String
    public var version: String
    /// 可执行文件绝对路径
    public var executable: String
    public var args: [String]
    public var installedAt: Date

    public init(id: String, version: String, executable: String, args: [String], installedAt: Date = Date()) {
        self.id = id
        self.version = version
        self.executable = executable
        self.args = args
        self.installedAt = installedAt
    }
}

// MARK: - 下载器

/// 压缩包下载器(可替换,便于测试)。
public protocol ArchiveDownloading: Sendable {
    /// 下载文件到本地路径。
    /// - Parameters:
    ///   - url: 下载地址
    ///   - destination: 目标文件
    ///   - progress: 进度回调(0...1;未知大小时为 nil)
    func download(from url: URL, to destination: URL, progress: @escaping @Sendable (Double?) -> Void) async throws
}

/// 基于 `URLSession` 的下载器:带进度,任务取消时终止下载。
public struct URLSessionDownloader: ArchiveDownloading {
    public init() {}

    public func download(from url: URL, to destination: URL, progress: @escaping @Sendable (Double?) -> Void) async throws {
        let delegate = DownloadDelegate(destination: destination, progress: progress)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: url)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                delegate.continuation = continuation
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }
}

/// 下载委托:把临时文件移动到目标位置并回调进度。
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let destination: URL
    let progress: @Sendable (Double?) -> Void
    var continuation: CheckedContinuation<Void, Error>?
    private let lock = NSLock()
    private var finished = false

    init(destination: URL, progress: @escaping @Sendable (Double?) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    private func finish(_ result: Result<Void, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = continuation
        lock.unlock()
        continuation?.resume(with: result)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progress(totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : nil)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            finish(.failure(AgentInstallError.downloadFailed("HTTP \(http.statusCode)")))
            return
        }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            finish(.success(()))
        } catch {
            finish(.failure(AgentInstallError.downloadFailed(error.localizedDescription)))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
    }
}

// MARK: - 安装器

/// Agent 安装器。
public struct AgentInstaller: Sendable {
    /// 允许下载压缩包的主机(精确匹配)。
    public static let allowedArchiveHosts: Set<String> = ["dl.google.com"]

    /// 默认安装根目录:`~/Library/Application Support/OhMyAgent/agents`。
    public static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OhMyAgent", isDirectory: true)
            .appendingPathComponent("agents", isDirectory: true)
    }

    public let root: URL
    private let downloader: any ArchiveDownloading
    private let allowedHosts: Set<String>

    /// - Parameters:
    ///   - root: 安装根目录
    ///   - downloader: 下载器(测试可注入)
    ///   - allowedHosts: 允许的下载主机(测试可注入)
    public init(root: URL = AgentInstaller.defaultRoot, downloader: any ArchiveDownloading = URLSessionDownloader(), allowedHosts: Set<String> = AgentInstaller.allowedArchiveHosts) {
        self.root = root
        self.downloader = downloader
        self.allowedHosts = allowedHosts
    }

    /// 校验下载地址:必须 HTTPS、无用户信息、主机在白名单内。
    /// - Parameter urlString: 压缩包地址
    /// - Returns: 通过校验的 URL
    public func validate(archive urlString: String) throws -> URL {
        guard let url = URL(string: urlString), url.scheme == "https", url.user == nil, url.password == nil,
              let host = url.host?.lowercased(), allowedHosts.contains(host) else {
            throw AgentInstallError.untrustedSource(URL(string: urlString)?.host ?? urlString)
        }
        return url
    }

    /// 校验 Agent 标识(只允许字母、数字、连字符、下划线、点,避免路径注入)。
    private func validate(id: String) throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        guard !id.isEmpty, id != ".", id != "..", id.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { throw AgentInstallError.invalidIdentifier(id) }
    }

    /// 安装(或升级)一个 Agent。
    /// - Parameters:
    ///   - agent: 注册表条目
    ///   - platform: 平台标识,默认当前平台
    ///   - progress: 进度回调
    /// - Returns: 已安装信息
    public func install(_ agent: RegistryAgent, platform: String = ACPRegistry.currentPlatform,
                        progress: @escaping @Sendable (AgentInstallProgress) -> Void = { _ in }) async throws -> InstalledAgent {
        try validate(id: agent.id)
        try validate(id: agent.version)
        guard let binary = agent.binary[platform] else { throw AgentInstallError.unsupportedPlatform(platform) }
        let archiveURL = try validate(archive: binary.archive)
        let started = ContinuousClock.now

        let fm = FileManager.default
        let staging = root.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        // 1. 下载
        let archive = staging.appendingPathComponent("archive.zip")
        progress(.downloading(0))
        do {
            try await downloader.download(from: archiveURL, to: archive) { progress(.downloading($0)) }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as AgentInstallError {
            throw error
        } catch {
            if (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw AgentInstallError.downloadFailed(error.localizedDescription)
        }
        try Task.checkCancellation()
        let size = (try? fm.attributesOfItem(atPath: archive.path)[.size] as? Int) ?? 0
        guard size > 1024 else { throw AgentInstallError.corruptArchive }

        // 2. 解压(ditto 与系统「归档实用工具」一致,保留权限与符号链接)
        progress(.extracting)
        let extracted = staging.appendingPathComponent("payload", isDirectory: true)
        try fm.createDirectory(at: extracted, withIntermediateDirectories: true)
        try await Self.run("/usr/bin/ditto", ["-x", "-k", archive.path, extracted.path])
        try Self.verifyContained(extracted)

        // 3. 定位可执行文件并设置权限
        progress(.finalizing)
        let executable = extracted.appendingPathComponent(binary.cmd).standardizedFileURL
        guard Self.isInside(executable, root: extracted), fm.fileExists(atPath: executable.path) else { throw AgentInstallError.missingExecutable(binary.cmd) }
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        // 官方压缩包不带隔离标记;若下载链路附带了,这里清除,避免首次运行被 Gatekeeper 拦下
        _ = try? await Self.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", extracted.path])

        // 4. 原子安装:同卷 move,先清理旧版本
        let agentDir = root.appendingPathComponent(agent.id, isDirectory: true)
        let destination = agentDir.appendingPathComponent(agent.version, isDirectory: true)
        try fm.createDirectory(at: agentDir, withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: extracted, to: destination)

        let relative = String(executable.path.dropFirst(extracted.standardizedFileURL.path.count + 1))
        let installed = InstalledAgent(id: agent.id, version: agent.version, executable: destination.appendingPathComponent(relative).path, args: binary.args)
        let manifest = try JSONEncoder.manifest.encode(installed)
        try manifest.write(to: agentDir.appendingPathComponent("manifest.json"), options: .atomic)
        // 只保留当前版本
        for item in (try? fm.contentsOfDirectory(atPath: agentDir.path)) ?? [] where item != agent.version && item != "manifest.json" {
            try? fm.removeItem(at: agentDir.appendingPathComponent(item))
        }
        Log.agent.info("Agent 已安装", ["agent": agent.id, "version": agent.version, "ms": "\(Int(started.duration(to: .now) / .milliseconds(1)))", "bytes": "\(size)"])
        return installed
    }

    /// 读取已安装信息;清单缺失或可执行文件不存在时为 nil。
    /// - Parameter id: Agent 标识
    public func installed(id: String) -> InstalledAgent? {
        guard (try? validate(id: id)) != nil else { return nil }
        let manifest = root.appendingPathComponent(id).appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifest), let item = try? JSONDecoder.manifest.decode(InstalledAgent.self, from: data),
              FileManager.default.isExecutableFile(atPath: item.executable) else { return nil }
        return item
    }

    /// 卸载:删除整个 Agent 目录(含登录之外的全部已安装文件)。
    /// - Parameter id: Agent 标识
    public func uninstall(id: String) throws {
        try validate(id: id)
        let dir = root.appendingPathComponent(id, isDirectory: true)
        if FileManager.default.fileExists(atPath: dir.path) { try FileManager.default.removeItem(at: dir) }
        Log.agent.info("Agent 已卸载", ["agent": id])
    }

    // MARK: 内部工具

    /// 是否需要更新:已安装版本与注册表版本不同。
    /// - Parameters:
    ///   - installed: 已安装信息
    ///   - latest: 注册表条目
    public static func needsUpdate(installed: InstalledAgent, latest: RegistryAgent) -> Bool { installed.version != latest.version }

    /// 路径是否位于根目录内(已标准化)。
    static func isInside(_ url: URL, root: URL) -> Bool {
        let base = root.standardizedFileURL.path
        return url.standardizedFileURL.path.hasPrefix(base + "/")
    }

    /// 校验解压结果:任何符号链接解析后都必须仍在解压目录内。
    static func verifyContained(_ directory: URL) throws {
        let base = directory.resolvingSymlinksInPath()
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey]) else { return }
        for case let url as URL in enumerator {
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                let target = url.resolvingSymlinksInPath()
                if !target.path.hasPrefix(base.path + "/") && target.path != base.path { throw AgentInstallError.unsafeArchive }
            }
        }
    }

    /// 在后台线程运行外部命令并等待结束;失败时抛出带 stderr 摘要的错误。
    @discardableResult
    static func run(_ launchPath: String, _ arguments: [String]) async throws -> Int32 {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: launchPath)
            process.arguments = arguments
            let errorPipe = Pipe()
            process.standardError = errorPipe
            process.standardOutput = FileHandle.nullDevice
            process.terminationHandler = { finished in
                let text = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                if finished.terminationStatus == 0 {
                    continuation.resume(returning: 0)
                } else {
                    continuation.resume(throwing: AgentInstallError.extractFailed(String(text.suffix(200)).trimmingCharacters(in: .whitespacesAndNewlines)))
                }
            }
            do { try process.run() } catch { continuation.resume(throwing: AgentInstallError.extractFailed(error.localizedDescription)) }
        }
    }
}

private extension JSONEncoder {
    static var manifest: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var manifest: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
