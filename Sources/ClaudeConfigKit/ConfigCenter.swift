// @author ixxxxoooo
// 配置中心:聚合各类存储的快照供界面使用,监听文件变化自动刷新,封装增删改与 CLI 调用。

import Foundation
import Observation

/// 某一时刻的配置快照(可跨线程传递)。
public struct ConfigSnapshot: Sendable {
    public var mcp: [MCPServerEntry] = []
    public var skills: [MarkdownItem] = []
    public var agents: [MarkdownItem] = []
    public var hooks: [HookEntry] = []
    public var plugins: [InstalledPlugin] = []
    public var marketplaces: [PluginMarketplace] = []
    public var memory: [MemoryFile] = []
    /// 各区块读取失败的原因(如 JSON 损坏),键为区块名
    public var errors: [String: String] = [:]

    public init() {}
}

/// 配置中心。
@MainActor
@Observable
public final class ConfigCenter {
    public private(set) var snapshot = ConfigSnapshot()
    public private(set) var mcpHealth: [String: MCPHealthStatus] = [:]
    /// 是否正在检测 MCP 连接:由触发按钮原位展示进度,不占用整行忙碌横幅(避免内容被挤下去)
    public private(set) var isCheckingMCP = false
    public private(set) var isBusy = false
    public private(set) var busyMessage: String?
    /// 最近一次操作的错误(界面以提示条展示)
    public var lastError: String?
    /// 最近一次操作的成功提示
    public var lastNotice: String?

    public let paths: ClaudePaths
    private var runner: CLIRunner?
    @ObservationIgnored private var watcher: ConfigWatcher?
    @ObservationIgnored private var reloadTask: Task<Void, Never>?

    /// - Parameters:
    ///   - paths: 配置路径(含工作区)
    ///   - runner: `claude` CLI 执行器(可空,空时插件/健康检查不可用)
    public init(paths: ClaudePaths, runner: CLIRunner? = nil) {
        self.paths = paths
        self.runner = runner
    }

    /// 更新 CLI 执行器(工具链定位完成后调用)。
    public func setRunner(_ runner: CLIRunner?) { self.runner = runner }

    public var canRunCLI: Bool { runner != nil }

    // MARK: - 加载与监听

    /// 开始监听并加载。
    public func start() {
        reload()
        guard watcher == nil else { return }
        let watcher = ConfigWatcher(paths: paths) { [weak self] in
            Task { @MainActor in self?.reload() }
        }
        watcher.start()
        self.watcher = watcher
    }

    /// 停止监听。
    public func stop() {
        watcher?.stop()
        watcher = nil
        reloadTask?.cancel()
    }

    /// 重新读取所有配置(后台线程执行,结果回到主线程)。
    public func reload() {
        reloadTask?.cancel()
        let paths = paths
        reloadTask = Task {
            let result = await Task.detached(priority: .userInitiated) { Self.load(paths: paths) }.value
            guard !Task.isCancelled else { return }
            snapshot = result
        }
    }

    /// 同步读取全部配置(供测试与后台线程使用)。
    nonisolated public static func load(paths: ClaudePaths) -> ConfigSnapshot {
        var snapshot = ConfigSnapshot()
        let plugins = PluginStore(paths: paths)
        let roots = plugins.enabledRoots()
        func capture<T>(_ section: String, _ fallback: T, _ body: () throws -> T) -> T {
            do { return try body() } catch { snapshot.errors[section] = error.localizedDescription; return fallback }
        }
        snapshot.mcp = capture("MCP", []) { try MCPStore(paths: paths).list() }
        snapshot.skills = SkillStore(paths: paths, pluginRoots: roots).list()
        snapshot.agents = AgentStore(paths: paths, pluginRoots: roots).list()
        snapshot.hooks = capture("Hooks", []) { try HooksStore(paths: paths, pluginRoots: roots).list() }
        snapshot.plugins = plugins.installed()
        snapshot.marketplaces = plugins.marketplaces()
        snapshot.memory = MemoryStore(paths: paths).list()
        return snapshot
    }

    // MARK: - 通用动作封装

    /// 执行一次同步修改:失败时记录错误,成功后刷新并给出提示。
    /// - Parameters:
    ///   - notice: 成功提示
    ///   - body: 修改动作
    /// - Returns: 是否成功
    @discardableResult
    public func perform(_ notice: String? = nil, _ body: () throws -> Void) -> Bool {
        do {
            try body()
            lastError = nil
            if let notice { lastNotice = notice }
            reload()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// 执行 CLI 命令并在结束后刷新。
    /// - Parameters:
    ///   - arguments: 参数
    ///   - message: 进行中提示
    ///   - notice: 成功提示
    ///   - timeout: 超时秒数
    @discardableResult
    public func runCLI(_ arguments: [String], message: String, notice: String, timeout: TimeInterval = 180) async -> Bool {
        guard let runner else {
            lastError = String(localized: "没有找到 claude 命令行工具,请在「设置 → 高级」中指定路径")
            return false
        }
        isBusy = true
        busyMessage = message
        defer { isBusy = false; busyMessage = nil }
        let result = await runner.run(arguments, in: paths.workspace, timeout: timeout)
        if result.succeeded {
            lastError = nil
            lastNotice = notice
        } else {
            lastError = result.failureMessage
        }
        reload()
        return result.succeeded
    }

    /// 运行 `claude mcp list` 检测各服务器连接状态。
    public func checkMCPHealth() async {
        guard let runner else {
            lastError = String(localized: "没有找到 claude 命令行工具")
            return
        }
        guard !isCheckingMCP else { return }
        isCheckingMCP = true
        defer { isCheckingMCP = false }
        let result = await runner.run(["mcp", "list"], in: paths.workspace, timeout: 60)
        guard result.succeeded else { lastError = result.failureMessage; return }
        mcpHealth = Dictionary(MCPStore.parseHealth(result.standardOutput).map { ($0.name, $0) }, uniquingKeysWith: { _, last in last })
    }
}
