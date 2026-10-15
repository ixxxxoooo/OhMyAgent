// @author ygw
// 会话模型:一个窗口对应一个 SessionModel,独占一个 Agent 子进程与一个 ACP 会话。
// 后台:事件接收与合并;主 actor:只应用合并后的批次。

import ACPKit
import AgentHost
import DiffKit
import Foundation
import Observation
import OMLog
import Synchronization

/// 待处理的权限请求。
@MainActor
@Observable
public final class PermissionPrompt: Identifiable {
    public nonisolated let id = UUID()
    public let request: PermissionRequest
    /// 工具标题(来自请求中的 toolCall)
    public let title: String
    public let kind: ToolKind
    /// 请求中携带的工具调用快照(可能含 Diff 预览、计划文本)
    public let tool: ToolCall
    public var isResolved = false
    private var continuation: CheckedContinuation<PermissionOutcome, Never>?

    init(request: PermissionRequest, continuation: CheckedContinuation<PermissionOutcome, Never>) {
        self.request = request
        self.title = request.toolCallRaw["title"]?.stringValue ?? "工具调用"
        self.kind = ToolKind(rawOrOther: request.toolCallRaw["kind"]?.stringValue)
        self.tool = ToolCall(json: request.toolCallRaw)
        self.continuation = continuation
    }

    /// 选择一个选项并回复 Agent。
    /// - Parameter optionId: 选项 ID
    public func choose(_ optionId: String) {
        resolve(.selected(optionId: optionId))
    }

    /// 取消(例如轮次被取消)。
    public func cancel() {
        resolve(.cancelled)
    }

    private func resolve(_ outcome: PermissionOutcome) {
        guard let continuation else { return }
        self.continuation = nil
        isResolved = true
        continuation.resume(returning: outcome)
    }
}

/// 客户端能力开关(设置页可调整;默认只开启提问表单)。
public struct ClientFeatures: Sendable, Equatable {
    /// 由客户端代理文件读写(Agent 读写经过 OhMyAgent)
    public var fileSystem = false
    /// 由客户端提供终端(命令输出内嵌到工具卡片)
    public var terminal = false
    /// 支持 Agent 向用户提问(AskUserQuestion、MCP 表单)
    public var elicitation = true

    public init() {}

    /// 从用户默认值读取。
    public static func load(_ defaults: UserDefaults = .standard) -> ClientFeatures {
        var features = ClientFeatures()
        if defaults.object(forKey: "feature.fileSystem") != nil { features.fileSystem = defaults.bool(forKey: "feature.fileSystem") }
        if defaults.object(forKey: "feature.terminal") != nil { features.terminal = defaults.bool(forKey: "feature.terminal") }
        if defaults.object(forKey: "feature.elicitation") != nil { features.elicitation = defaults.bool(forKey: "feature.elicitation") }
        return features
    }

    /// 声明给 Agent 的额外能力。
    var extraCapabilities: [String: JSONValue] {
        elicitation ? ["elicitation": ["form": .object([:]), "url": .object([:])]] : [:]
    }
}

/// 反向请求委托:权限、提问转交主 actor 的会话模型;文件与终端在本地实现。
struct SessionDelegate: ACPClientDelegate {
    let workspace: String
    let terminals: TerminalManager
    let ask: @Sendable (PermissionRequest) async -> PermissionOutcome
    let ask2: @Sendable (String, JSONValue?) async -> JSONValue

    func requestPermission(_ request: PermissionRequest) async -> PermissionOutcome {
        await ask(request)
    }

    func elicit(method: String, params: JSONValue?) async throws -> JSONValue {
        await ask2(method, params)
    }

    func readTextFile(sessionId: String, path: String, line: Int?, limit: Int?) async throws -> String {
        let text: String
        do { text = try String(contentsOfFile: path, encoding: .utf8) } catch {
            Log.tool.error("fs/read_text_file 失败", error: error, ["path": path, "session": String(sessionId.prefix(8))])
            throw error
        }
        Log.tool.debug("fs/read_text_file", ["path": path, "bytes": "\(text.utf8.count)", "line": line.map(String.init) ?? "-", "limit": limit.map(String.init) ?? "-"])
        guard line != nil || limit != nil else { return text }
        let lines = text.components(separatedBy: "\n")
        let start = max((line ?? 1) - 1, 0)
        guard start < lines.count else { return "" }
        let end = limit.map { min(start + $0, lines.count) } ?? lines.count
        return lines[start..<end].joined(separator: "\n")
    }

    func writeTextFile(sessionId: String, path: String, content: String) async throws {
        // 只允许写入工作区内,防止越权覆盖
        let root = URL(fileURLWithPath: workspace).standardizedFileURL.path
        let target = URL(fileURLWithPath: path).standardizedFileURL
        guard target.path == root || target.path.hasPrefix(root + "/") else {
            Log.tool.warning("fs/write_text_file 被拒绝:不在工作区内", ["path": path, "workspace": root])
            throw JSONRPCError(code: JSONRPCError.invalidParams, message: "仅允许写入工作区内的文件: \(path)")
        }
        do {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: target, atomically: true, encoding: .utf8)
        } catch {
            Log.tool.error("fs/write_text_file 失败", error: error, ["path": path])
            throw error
        }
        Log.tool.info("fs/write_text_file", ["path": path, "bytes": "\(content.utf8.count)"])
    }

    func createTerminal(sessionId: String, command: String, args: [String], env: [String: String], cwd: String?, outputByteLimit: Int?) async throws -> String {
        try await terminals.create(command: command, args: args, env: env, cwd: cwd, outputByteLimit: outputByteLimit ?? ClientPrefs.terminalOutputLimit())
    }

    func terminalOutput(terminalId: String) async throws -> TerminalOutputSnapshot {
        try await terminals.output(terminalId)
    }

    func waitForTerminalExit(terminalId: String) async throws -> TerminalOutputSnapshot {
        try await terminals.waitForExit(terminalId)
    }

    func killTerminal(terminalId: String) async throws {
        try await terminals.kill(terminalId)
    }

    func releaseTerminal(terminalId: String) async throws {
        try await terminals.release(terminalId)
    }
}

/// 文件快照器:在工具调用开始时(事件到达的后台线程上,先于合并与主线程处理)读取受影响文件的内容。
/// 这样即使 Agent 在“自动接受编辑”模式下立刻写盘,也能拿到修改前的内容。
final class FileSnapshotter: Sendable {
    private let shots = Mutex<[String: [String: String?]]>([:])

    /// 受影响的路径:locations 与 diff 内容中的路径。
    static func paths(of call: ToolCall) -> [String] {
        guard call.kind == .edit || call.kind == .delete || call.kind == .move else { return [] }
        var paths = call.locations.map(\.path)
        for case .diff(let path, _, _) in call.content where !paths.contains(path) { paths.append(path) }
        return paths
    }

    /// 首次见到该工具调用时拍快照(幂等)。
    func capture(_ call: ToolCall) {
        guard !call.status.isTerminal else { return }
        let paths = Self.paths(of: call)
        guard !paths.isEmpty else { return }
        let already = shots.withLock { $0[call.toolCallId] != nil }
        guard !already else { return }
        var shot: [String: String?] = [:]
        for path in paths { shot.updateValue(SessionModel.readSmallFile(path), forKey: path) }
        shots.withLock { if $0[call.toolCallId] == nil { $0[call.toolCallId] = shot } }
    }

    /// 取出并移除快照。
    func take(_ id: String) -> [String: String?]? {
        shots.withLock { $0.removeValue(forKey: id) }
    }
}

/// 文件查看请求(在编辑器面板中打开)。
public struct FileViewRequest: Identifiable, Sendable, Equatable {
    public var id: String { "\(path):\(line ?? 0)" }
    public var path: String
    public var line: Int?

    public init(path: String, line: Int? = nil) {
        self.path = path
        self.line = line
    }
}

/// 连接阶段。
public enum SessionPhase: Sendable, Equatable {
    case idle
    case connecting
    case ready
    case failed(String)
}

/// 会话模型。
@MainActor
@Observable
public final class SessionModel {
    public let workspace: URL
    public let descriptor: AgentDescriptor
    /// 实际使用的描述符(ACP 适配器不可用且开启兜底时会自动变为直连)
    public private(set) var activeDescriptor: AgentDescriptor
    /// 用户在界面中选中的文字(Bridge 的 get_selection 读取)
    public var selectedText: String?
    /// 系统通知发送器(由应用层注入,Bridge 的 notify 使用)
    public var notifier: (@MainActor (String, String) -> Void)?
    var bridge: BridgeServer?
    var mcpServers: [MCPServerConfig] = []
    public let timeline = TimelineStore()

    public private(set) var phase: SessionPhase = .idle
    public private(set) var isRunning = false { didSet { if isRunning != oldValue { publishAttention() } } }
    public private(set) var agentName: String
    public private(set) var configOptions: [SessionConfigOption] = []
    public private(set) var availableCommands: [AvailableCommand] = []
    public private(set) var usage: UsageUpdate?
    public private(set) var sessionTitle: String? { didSet { if sessionTitle != oldValue { recordRecent() } } }
    public private(set) var pendingPermissions: [PermissionPrompt] = [] { didSet { if pendingPermissions.isEmpty != oldValue.isEmpty { publishAttention() } } }
    public private(set) var pendingElicitations: [ElicitationPrompt] = [] { didSet { if pendingElicitations.isEmpty != oldValue.isEmpty { publishAttention() } } }
    /// 终端会话(按终端 ID)
    public private(set) var terminals: [String: TerminalSession] = [:]
    public private(set) var sessionId: String? { didSet { if sessionId != oldValue { publishAttention(); recordRecent() } } }
    /// 进程内唯一标识(注意力中心与通知使用)
    public let uid = UUID().uuidString
    /// 注意力中心(测试可注入)
    @ObservationIgnored public var attention: AttentionCenter = .shared
    /// 最近一次连接(启动适配器 + 握手 + 新建会话)耗时,用于诊断
    public private(set) var connectDuration: Duration?
    /// 当前工作区的历史会话(来自 `session/list`)
    public private(set) var history: [SessionSummary] = [] { didSet { onHistoryChanged?(history) } }
    /// 历史会话列表变化回调(工作台用于缓存,使项目树无需启动 Agent 即可显示会话)
    @ObservationIgnored public var onHistoryChanged: (([SessionSummary]) -> Void)?
    /// Agent 能力与鉴权方式
    public private(set) var capabilities = AgentCapabilities()
    /// 正在回放历史会话
    public private(set) var isReplaying = false
    /// 工作区文件索引(供 @ 补全)
    public let fileIndex = FileIndex()
    /// 最近的 stderr 行(诊断用,最多 200 行)
    public private(set) var diagnostics: [String] = []
    /// 连接完成后自动发送的排队消息
    public private(set) var queuedPrompt: String?
    /// 输入框草稿
    public var draft = ""
    /// 需要在编辑器面板中打开的文件
    public var viewerRequest: FileViewRequest?

    private var supervisor: AgentSupervisor?
    private var client: ACPClient?
    private var coalescer: EventCoalescer?
    private var pumpTasks: [Task<Void, Never>] = []
    private var promptTask: Task<Void, Never>?
    private var connectTask: Task<Void, Never>?
    private var isShuttingDown = false
    private var terminalManager: TerminalManager?
    private let checkpoints = CheckpointStore()
    private var turnNumber = 0
    private var turnStart: ContinuousClock.Instant?
    /// 带项目与会话标识的日志器。
    private var log: OMLogger {
        Log.session.with(["project": workspace.lastPathComponent, "session": sessionId.map { String($0.prefix(8)) } ?? "-"])
    }
    private let snapshotter = FileSnapshotter()
    /// 本轮累计的文件改动:路径 → (最初内容, 最新内容)
    private var turnChanges: [String: (original: String?, current: String)] = [:]
    private var turnChangeOrder: [String] = []
    /// 客户端能力
    public var features = ClientFeatures.load()

    /// 创建会话模型。
    /// - Parameters:
    ///   - workspace: 工作区目录
    ///   - descriptor: Agent 描述符
    public init(workspace: URL, descriptor: AgentDescriptor = Toolchain.defaultDescriptor()) {
        self.workspace = workspace
        self.descriptor = descriptor
        self.activeDescriptor = descriptor
        self.agentName = descriptor.name
        timeline.onToolChange = { [weak self] call in self?.observeTool(call) }
    }

    // MARK: - 连接

    /// 后台预热连接(幂等)。窗口首帧后调用。
    public func connect() {
        guard connectTask == nil, phase == .idle || isFailed else { return }
        phase = .connecting
        let connectStart = ContinuousClock.now
        let descriptor = activeDescriptor
        let cwd = workspace.path
        log.info("开始连接 Agent", ["agent": descriptor.id, "cwd": cwd])
        connectTask = Task { [weak self] in
            let tools = await Toolchain.shared.resolve()
            guard let self else { return }
            self.log.info("工具链解析完成", ["node": tools.nodePath ?? "-", "nodeVersion": tools.nodeVersion ?? "-", "claude": tools.claudePath ?? "-", "adapter": tools.adapterEntry ?? "-"])
            let environment = ClientPrefs.filterTerminalEnvironment(tools.environment, inherit: ClientPrefs.terminalInheritsEnvironment())
            let manager = TerminalManager(workspace: cwd, environment: { environment }, onCreated: { [weak self] created in
                Task { @MainActor in self?.registerTerminal(created) }
            })
            self.terminalManager = manager
            let delegate = SessionDelegate(
                workspace: cwd,
                terminals: manager,
                ask: { [weak self] request in
                    guard let self else { return .cancelled }
                    return await self.awaitPermission(request)
                },
                ask2: { [weak self] method, params in
                    guard let self else { return ["action": "cancel"] }
                    return await self.awaitElicitation(method: method, params: params)
                }
            )
            await self.resolveProvider(for: descriptor)
            let features = self.features
            let supervisor = AgentSupervisor(provider: AgentProviders.make(descriptor), cwd: cwd, delegate: delegate,
                                             fileSystem: features.fileSystem, terminal: features.terminal,
                                             extraCapabilities: features.extraCapabilities)
            do {
                let result = try await supervisor.start(tools: tools)
                guard let client = await supervisor.client else { throw AgentLaunchError.missingAdapter }
                self.attach(supervisor: supervisor, client: client, result: result)
                let registry = AgentRegistryStore().load()
                let prepared = self.prepareMCPServers(registry: registry, environment: tools.environment)
                self.mcpServers = prepared.servers
                self.bridge = prepared.bridge
                let setup = try await client.newSession(cwd: cwd, mcpServers: prepared.servers, meta: self.providerMeta)
                self.sessionId = setup.sessionId
                self.configOptions = setup.configOptions
                self.phase = .ready
                self.connectDuration = connectStart.duration(to: .now)
                self.log.info("Agent 已就绪", ["agent": result.agentName, "ms": "\(OMLogger.milliseconds(since: connectStart))", "mcpServers": "\(prepared.servers.count)", "bridge": prepared.bridge == nil ? "off" : "on"])
                self.connectTask = nil
                self.refreshHistory()
                self.flushQueuedPrompt()
            } catch {
                self.log.error("连接 Agent 失败", error: error, ["agent": descriptor.id, "ms": "\(OMLogger.milliseconds(since: connectStart))"])
                await supervisor.stop()
                self.bridge?.stop()
                self.bridge = nil
                self.connectTask = nil
                if self.shouldFallBackToDirect(error: error, descriptor: descriptor) {
                    self.log.warning("ACP 适配器不可用,回退直连通道")
                    self.activeDescriptor = .claudeDirect
                    self.agentName = AgentDescriptor.claudeDirect.name
                    self.phase = .idle
                    self.timeline.appendNotice("ACP 适配器不可用(\(error.localizedDescription))\n已自动改用直连通道:无工具审批弹窗,请在模式中选择 Accept edits 或 Bypass permissions。")
                    self.connect()
                } else {
                    self.phase = .failed(error.localizedDescription)
                }
            }
        }
    }

    /// 启动前提缺失(Node / 适配器)且开启了兜底时,改用直连通道。
    func shouldFallBackToDirect(error: Error, descriptor: AgentDescriptor, registry: AgentRegistryData = AgentRegistryStore().load()) -> Bool {
        guard descriptor.kind == .claudeACP, let launch = error as? AgentLaunchError else { return false }
        switch launch {
        case .missingNode, .missingAdapter: return registry.directFallback
        default: return false
        }
    }

    /// 本轮是否记录了该文件的改动。
    func hasTurnChange(at path: String) -> Bool {
        guard let item = turnChanges[path] else { return false }
        return item.original != item.current
    }

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    /// 重新连接(失败后重试)。
    public func reconnect() {
        shutdownProcess()
        phase = .idle
        connect()
    }

    private func attach(supervisor: AgentSupervisor, client: ACPClient, result: InitializeResult) {
        self.supervisor = supervisor
        self.client = client
        agentName = result.agentTitle ?? result.agentName
        capabilities = result.capabilities
        let coalescer = EventCoalescer()
        self.coalescer = coalescer
        // 后台:读取事件并合并
        let snapshotter = snapshotter
        let reader = Task.detached(priority: .userInitiated) {
            for await event in client.events {
                if case .sessionUpdate(_, let update) = event {
                    Self.captureSnapshots(update, snapshotter)
                }
                coalescer.push(event)
            }
            coalescer.finish()
        }
        // 主 actor:按批应用
        let applier = Task { [weak self] in
            for await batch in coalescer.batches {
                guard let self else { return }
                self.handle(batch)
            }
        }
        pumpTasks = [reader, applier]
    }

    // MARK: - 发送与取消

    /// 发送消息。连接未就绪时排队,就绪后自动发送。
    /// - Parameter text: 文本
    public func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isRunning else { return }
        // 本地命令不发给 Agent
        if trimmed == "/new" || trimmed == "/clear" {
            newConversation()
            return
        }
        switch phase {
        case .ready:
            start(prompt: trimmed)
        case .idle, .failed:
            queuedPrompt = trimmed
            connect()
        case .connecting:
            queuedPrompt = trimmed
        }
    }

    /// 草稿发送便捷方法。
    public func sendDraft() {
        let text = draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        draft = ""
        send(text)
    }

    private func flushQueuedPrompt() {
        guard let queued = queuedPrompt else { return }
        queuedPrompt = nil
        start(prompt: queued)
    }

    /// 当前会话使用的模型提供商名称(未启用提供商时为 nil,即沿用 ~/.claude 配置)
    public private(set) var providerName: String?
    /// 提供商的会话 `_meta`(含密钥,仅内存持有,禁止记录)
    @ObservationIgnored private var providerMeta: JSONValue?
    /// 提供商地址(发送前探测用)
    @ObservationIgnored private var providerURL: URL?
    /// 提供商目录(测试可注入;默认 Application Support)
    @ObservationIgnored public var providerDirectory: URL = ProviderStorage.defaultDirectory
    /// 提供商解析使用的环境(测试可注入)
    @ObservationIgnored public var providerEnvironment: [String: String] = ProcessInfo.processInfo.environment

    /// 模型网关探测器(默认探测 `ANTHROPIC_BASE_URL`;测试可注入)。
    @ObservationIgnored public var gatewayChecker: (@Sendable () async -> GatewayStatus)?
    /// 最近一次收到 Agent 事件的时间(卡死看门狗使用)
    @ObservationIgnored private var lastActivity = ContinuousClock.now
    @ObservationIgnored private var watchdogTask: Task<Void, Never>?
    /// 无事件超过该时长则怀疑卡死并重新探测网关
    static let stallThreshold: Duration = .seconds(20)

    /// 发送前探测网关;仅对真实 Claude 通道生效。启用了模型提供商时探测提供商地址。
    private func probeGateway() async -> GatewayStatus {
        if let gatewayChecker { return await gatewayChecker() }
        guard activeDescriptor.kind == .claudeACP else { return .notConfigured }
        if let providerURL { return await ModelGateway.probe(providerURL) }
        return await ModelGateway.check()
    }

    /// 解析启用的模型提供商(后台读盘);缺密钥/配置无效时提示并回退到 ~/.claude 默认配置。
    private func resolveProvider(for descriptor: AgentDescriptor) async {
        providerName = nil
        providerMeta = nil
        providerURL = nil
        guard descriptor.kind == .claudeACP else { return }
        let directory = providerDirectory
        let environment = providerEnvironment
        let outcome = await Task.detached(priority: .userInitiated) { () -> Result<ResolvedProvider?, ProviderStorage.ResolveError> in
            do { return .success(try ProviderStorage.resolveActive(directory: directory, environment: environment)) }
            catch let error as ProviderStorage.ResolveError { return .failure(error) }
            catch { return .success(nil) }
        }.value
        switch outcome {
        case .success(let resolved?):
            providerName = resolved.provider.name
            providerMeta = resolved.meta
            providerURL = resolved.provider.url
            log.info("使用模型提供商", ["provider": resolved.provider.id, "model": resolved.provider.model, "baseURL": ModelGateway.origin(of: resolved.provider.url ?? workspace)])
        case .success(nil):
            break
        case .failure(let error):
            log.warning("模型提供商不可用,回退默认配置", ["reason": error.localizedDescription])
            timeline.appendNotice(error.localizedDescription, isError: true)
        }
    }

    private func start(prompt: String) {
        guard let client, let sessionId else { return }
        // 非 Claude 通道(测试/脚本化 Agent)无需探测网关,保持同步发送
        guard gatewayChecker != nil || activeDescriptor.kind == .claudeACP else {
            beginTurn(prompt: prompt, client: client, sessionId: sessionId)
            return
        }
        isRunning = true
        promptTask = Task { [weak self] in
            // 先探测网关:代理没启动时,SDK 会静默重试 10 余次,界面看起来像卡死
            let status = await self?.probeGateway() ?? .notConfigured
            guard let self, self.isRunning else { return }
            if case .unreachable(let url, let reason) = status {
                self.log.error("模型网关不可达,未发送", ["gateway": ModelGateway.origin(of: url), "reason": reason])
                self.abortSend(prompt: prompt, message: ModelGateway.unreachableMessage(url: url, reason: reason))
                return
            }
            self.beginTurn(prompt: prompt, client: client, sessionId: sessionId)
        }
    }

    /// 真正开始一轮:写入用户消息、启动看门狗并发出 `session/prompt`。
    private func beginTurn(prompt: String, client: ACPClient, sessionId: String) {
        var blocks: [ContentBlock] = [.text(prompt)]
        for url in CompletionEngine.mentionedFiles(in: prompt, workspace: workspace) {
            blocks.append(.resourceLink(uri: url.absoluteString, name: url.lastPathComponent, mimeType: nil, title: nil))
        }
        timeline.appendUser(prompt)
        turnNumber += 1
        turnStart = ContinuousClock.now
        lastActivity = .now
        log.info("发送提示", ["turn": "\(turnNumber)", "chars": "\(prompt.count)", "mentions": "\(blocks.count - 1)"])
        turnChanges.removeAll()
        turnChangeOrder.removeAll()
        isRunning = true
        startWatchdog()
        promptTask = Task { [weak self] in
            do {
                let reason = try await client.prompt(sessionId: sessionId, content: blocks)
                self?.finishTurn(reason: reason, error: nil)
            } catch {
                self?.finishTurn(reason: nil, error: error)
            }
        }
    }

    /// 发送前失败:不产生用户消息,把文本放回输入框并给出提示。
    private func abortSend(prompt: String, message: String) {
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { draft = prompt }
        timeline.appendNotice(message, isError: true)
        isRunning = false
        promptTask = nil
    }

    /// 卡死看门狗:轮次中长时间没有任何事件时重新探测网关,不可达则取消并提示。
    private func startWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, self.isRunning, !Task.isCancelled else { return }
                guard self.pendingPermissions.isEmpty, self.pendingElicitations.isEmpty else { continue }
                guard self.lastActivity.duration(to: .now) > Self.stallThreshold else { continue }
                if case .unreachable(let url, let reason) = await self.probeGateway() {
                    self.log.error("轮次卡死:网关不可达,取消", ["gateway": ModelGateway.origin(of: url), "reason": reason])
                    self.stallMessage = ModelGateway.unreachableMessage(url: url, reason: reason)
                    self.cancel()
                    return
                }
                self.lastActivity = .now   // 网关正常:上游仍在思考,继续等待
            }
        }
    }

    /// 看门狗判定卡死时待展示的提示(轮次结束时输出)。
    @ObservationIgnored private var stallMessage: String?

    private func finishTurn(reason: StopReason?, error: Error?) {
        // 先把已合并但尚未应用的事件落入时间线,再结束轮次
        watchdogTask?.cancel()
        watchdogTask = nil
        coalescer?.flush()
        let turnMs = turnStart.map { OMLogger.milliseconds(since: $0) } ?? 0
        if let error {
            log.error("轮次失败", error: error, ["turn": "\(turnNumber)", "ms": "\(turnMs)"])
        } else {
            log.info("轮次结束", ["turn": "\(turnNumber)", "reason": reason.map { "\($0)" } ?? "-", "ms": "\(turnMs)", "changedFiles": "\(turnChangeOrder.count)"])
        }
        Task { [weak self] in
            // 让出一次,使 flush 产生的批次先被应用
            await Task.yield()
            guard let self else { return }
            self.timeline.finishStreaming()
            if let stall = self.stallMessage {
                self.stallMessage = nil
                self.timeline.appendNotice(stall, isError: true)
            } else if let error {
                if !self.isShuttingDown {
                    if let rpc = error as? JSONRPCError, rpc.code == -32000 {
                        self.timeline.appendNotice("Claude Code 尚未登录或登录已失效:请在终端运行 claude 完成登录后重试。", isError: true)
                    } else {
                        self.timeline.appendNotice("请求失败:\(error.localizedDescription)", isError: true)
                    }
                }
            } else if reason == .refusal {
                self.timeline.appendNotice("模型拒绝了该请求。")
            } else if reason == .maxTokens {
                self.timeline.appendNotice("已达到输出上限,回复被截断。")
            } else if reason == .maxTurnRequests {
                self.timeline.appendNotice("已达到单轮请求上限。")
            }
            self.publishTurnChanges()
            self.isRunning = false
            self.promptTask = nil
            self.refreshHistory()
        }
    }

    /// 取消当前轮次,并拒绝所有待处理权限。
    public func cancel() {
        guard isRunning, let client, let sessionId else { return }
        log.info("用户取消当前轮次", ["turn": "\(turnNumber)"])
        cancelPendingPrompts()
        Task { await client.cancel(sessionId: sessionId) }
    }

    /// 开始新对话:复用同一 Agent 进程创建新的 ACP 会话,并清空时间线。
    public func newConversation() {
        guard let client, phase == .ready else { return }
        cancel()
        let cwd = workspace.path
        timeline.reset()
        sessionTitle = nil
        usage = nil
        turnChanges.removeAll()
        turnChangeOrder.removeAll()
        Task { await checkpoints.reset() }
        let servers = mcpServers
        let meta = providerMeta
        Task { [weak self] in
            do {
                let setup = try await client.newSession(cwd: cwd, mcpServers: servers, meta: meta)
                self?.sessionId = setup.sessionId
                self?.configOptions = setup.configOptions
            } catch {
                self?.log.error("创建新对话失败", error: error)
                self?.timeline.appendNotice("创建新对话失败:\(error.localizedDescription)", isError: true)
            }
        }
    }

    // MARK: - 历史会话

    /// 刷新当前工作区的历史会话列表。
    public func refreshHistory() {
        guard let client, capabilities.canList else { return }
        let cwd = workspace.path
        Task { [weak self] in
            guard let result = try? await client.listSessions(cwd: cwd) else { return }
            let sorted = result.sessions.sorted { ($0.updatedAt ?? "") > ($1.updatedAt ?? "") }
            self?.history = sorted
        }
    }

    /// 打开历史会话:优先 `session/load`(回放历史),否则 `session/resume`。
    /// - Parameter summary: 会话摘要
    public func openSession(_ summary: SessionSummary) {
        guard let client, phase == .ready, summary.sessionId != sessionId, capabilities.loadSession || capabilities.canResume else { return }
        cancel()
        timeline.reset()
        turnChanges.removeAll()
        turnChangeOrder.removeAll()
        Task { await checkpoints.reset() }
        sessionTitle = summary.title
        usage = nil
        sessionId = summary.sessionId
        isReplaying = true
        let cwd = workspace.path
        let canLoad = capabilities.loadSession
        let servers = mcpServers
        let meta = providerMeta
        Task { [weak self] in
            do {
                let setup = canLoad
                    ? try await client.loadSession(sessionId: summary.sessionId, cwd: cwd, mcpServers: servers, meta: meta)
                    : try await client.resumeSession(sessionId: summary.sessionId, cwd: cwd, mcpServers: servers, meta: meta)
                self?.configOptions = setup.configOptions.isEmpty ? (self?.configOptions ?? []) : setup.configOptions
            } catch {
                self?.timeline.appendNotice("打开会话失败:\(error.localizedDescription)", isError: true)
            }
            await self?.settleEvents()
            self?.timeline.finishStreaming()
            self?.isReplaying = false
        }
    }

    /// 分叉当前会话,并切换到分叉出的新会话。
    public func forkCurrentSession() {
        guard let client, let sessionId, capabilities.canFork, !isRunning else { return }
        let cwd = workspace.path
        let servers = mcpServers
        let meta = providerMeta
        Task { [weak self] in
            do {
                let setup = try await client.forkSession(sessionId: sessionId, cwd: cwd, mcpServers: servers, meta: meta)
                self?.sessionId = setup.sessionId
                self?.timeline.appendNotice("已从此处分叉出新会话,后续对话不会影响原会话。")
                if !setup.configOptions.isEmpty { self?.configOptions = setup.configOptions }
                self?.refreshHistory()
            } catch {
                self?.timeline.appendNotice("分叉失败:\(error.localizedDescription)", isError: true)
            }
        }
    }

    /// 删除历史会话。
    /// - Parameter summary: 会话摘要
    public func deleteSession(_ summary: SessionSummary) {
        guard let client, capabilities.canDelete, summary.sessionId != sessionId else { return }
        Task { [weak self] in
            try? await client.deleteSession(sessionId: summary.sessionId)
            self?.refreshHistory()
        }
    }

    /// 让已到达但尚在合并窗口中的事件先落入时间线。
    private func settleEvents() async {
        coalescer?.flush()
        try? await Task.sleep(for: .milliseconds(40))
    }

    // MARK: - 补全

    /// 计算补全候选。
    /// - Parameter context: 补全上下文
    /// - Returns: 候选项
    public func completionItems(for context: CompletionContext) async -> [CompletionItem] {
        switch context.trigger {
        case .slash:
            return CompletionEngine.slashItems(query: context.query, agentCommands: availableCommands)
        case .mention:
            await fileIndex.prepare(root: workspace)
            await fileIndex.waitUntilReady()
            let paths = await fileIndex.search(context.query)
            return paths.map { path in
                CompletionItem(kind: .file, title: (path as NSString).lastPathComponent,
                               subtitle: (path as NSString).deletingLastPathComponent, insertText: "@\(path) ")
            }
        }
    }

    /// 循环切换模式(Shift+Tab)。
    public func cycleMode() {
        guard let option = option(category: "mode"), option.options.count > 1 else { return }
        let current = option.currentValue.stringValue
        let index = option.options.firstIndex { $0.value == current } ?? -1
        setConfigOption(option.id, value: option.options[(index + 1) % option.options.count].value)
    }

    // MARK: - 配置选项

    /// 设置配置选项(模式、模型、思考强度等)。
    /// - Parameters:
    ///   - optionId: 选项 ID
    ///   - value: 新值
    public func setConfigOption(_ optionId: String, value: String) {
        guard let client, let sessionId else { return }
        Task { [weak self] in
            do {
                let updated = try await client.setConfigOption(sessionId: sessionId, configId: optionId, value: .string(value))
                if !updated.isEmpty { self?.configOptions = updated }
            } catch {
                self?.timeline.appendNotice("设置失败:\(error.localizedDescription)", isError: true)
            }
        }
    }

    /// 按类别取配置选项(`mode` / `model` / `thought_level`)。
    /// - Parameter category: 类别
    public func option(category: String) -> SessionConfigOption? {
        configOptions.first { $0.category == category }
    }

    // MARK: - 权限

    private func awaitPermission(_ request: PermissionRequest) async -> PermissionOutcome {
        snapshotter.capture(ToolCall(json: request.toolCallRaw))
        let call = ToolCall(json: request.toolCallRaw)
        log.info("请求权限", ["tool": call.title, "kind": "\(call.kind)", "toolCallId": call.toolCallId, "options": request.options.map(\.optionId).joined(separator: ",")])
        return await withCheckedContinuation { continuation in
            let prompt = PermissionPrompt(request: request, continuation: continuation)
            pendingPermissions.append(prompt)
        }
    }

    /// 回复权限并从队列移除。
    /// - Parameters:
    ///   - prompt: 请求
    ///   - optionId: 选项
    public func resolve(_ prompt: PermissionPrompt, optionId: String) {
        log.info("权限已回复", ["tool": prompt.title, "option": optionId])
        prompt.choose(optionId)
        pendingPermissions.removeAll { $0.id == prompt.id }
    }

    private func cancelPendingPrompts() {
        for prompt in pendingPermissions { prompt.cancel() }
        pendingPermissions.removeAll()
        for prompt in pendingElicitations { prompt.cancel() }
        pendingElicitations.removeAll()
    }

    // MARK: - 提问(Elicitation)

    private func awaitElicitation(method: String, params: JSONValue?) async -> JSONValue {
        guard method == "elicitation/create", let params else { return ["action": "cancel"] }
        let message = params["message"]?.stringValue ?? ""
        return await withCheckedContinuation { continuation in
            let prompt: ElicitationPrompt
            if params["mode"]?.stringValue == "url", let text = params["url"]?.stringValue, let url = URL(string: text),
               ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                prompt = ElicitationPrompt(message: message, mode: .url(url), fields: [], continuation: continuation)
            } else {
                prompt = ElicitationPrompt(message: message, mode: .form, fields: ElicitationParser.fields(from: params), continuation: continuation)
            }
            pendingElicitations.append(prompt)
        }
    }

    /// 回答提问后从队列移除。
    /// - Parameter prompt: 已处理的提问
    public func dismiss(_ prompt: ElicitationPrompt) {
        pendingElicitations.removeAll { $0.id == prompt.id }
    }

    // MARK: - 终端

    private func registerTerminal(_ created: TerminalCreated) {
        guard let manager = terminalManager else { return }
        let session = TerminalSession(id: created.id, command: created.command)
        terminals[created.id] = session
        session.startPolling(manager: manager)
    }

    /// 中断正在运行的终端命令(工具卡片上的“停止”按钮)。
    /// - Parameter terminalId: 终端 ID
    public func interruptTerminal(_ terminalId: String) {
        guard let manager = terminalManager else { return }
        log.info("用户中断终端", ["terminalId": terminalId])
        Task { try? await manager.kill(terminalId) }
    }

    // MARK: - 检查点与改动汇总

    /// 工具完成时:与开始前的快照比较并记录改动。
    private func observeTool(_ call: ToolCall) {
        if call.status.isTerminal { log.debug("工具结束", ["toolCallId": call.toolCallId, "title": call.title, "kind": "\(call.kind)", "status": "\(call.status)"]) }
        let paths = FileSnapshotter.paths(of: call)
        guard !paths.isEmpty, call.status == .completed, let shot = snapshotter.take(call.toolCallId) else { return }
        for path in paths {
            let before: String? = shot[path] ?? nil
            let after = Self.readSmallFile(path)
            guard let after, after != before else { continue }
            if let existing = turnChanges[path] {
                turnChanges[path] = (existing.original, after)
            } else {
                turnChanges[path] = (before, after)
                turnChangeOrder.append(path)
            }
            let turn = turnNumber
            let original = turnChanges[path]?.original
            Task { [checkpoints] in await checkpoints.record(turn: turn, path: path, oldText: original, newText: after) }
        }
    }

    /// 在事件进入合并器之前拍快照(含子 Agent 内部的调用)。
    nonisolated static func captureSnapshots(_ update: SessionUpdate, _ snapshotter: FileSnapshotter) {
        switch update {
        case .toolCall(let call): snapshotter.capture(call)
        case .childUpdate(_, let inner): captureSnapshots(inner, snapshotter)
        default: break
        }
    }

    /// 读取不超过 1MB 的 UTF-8 文件;不存在或过大返回 nil。
    nonisolated static func readSmallFile(_ path: String) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attributes[.size] as? NSNumber)?.int64Value, size <= 1_048_576 else { return nil }
        return try? String(contentsOfFile: path, encoding: .utf8)
    }

    private func publishTurnChanges() {
        let changes = turnChangeOrder.compactMap { path -> FileChange? in
            guard let item = turnChanges[path], item.original != item.current else { return nil }
            return FileChange(path: path, original: item.original, current: item.current)
        }
        turnChanges.removeAll()
        turnChangeOrder.removeAll()
        timeline.appendChanges(turn: turnNumber, changes: changes)
    }

    /// 回退文件改动(整文件或指定块)。
    /// - Parameters:
    ///   - change: 改动记录
    ///   - hunks: 需要回退的块;nil 表示整文件
    public func revert(_ change: FileChange, hunks: Set<Int>? = nil) {
        Task { [weak self, checkpoints] in
            let outcome = await checkpoints.revert(path: change.path, hunks: hunks)
            guard self != nil else { return }
            switch outcome {
            case .reverted:
                if hunks == nil {
                    change.status = .reverted
                } else if let text = Self.readSmallFile(change.path) {
                    change.updateCurrent(text)
                    change.status = change.diff.isEmpty ? .reverted : .partiallyReverted
                }
            case .conflict: change.status = .conflict
            case .notFound: change.status = .failed("没有可用的检查点")
            case .failed(let message): change.status = .failed(message)
            }
        }
    }

    /// 回退一份汇总中尚未回退的全部文件。
    /// - Parameter entry: `.changes` 条目
    public func revertAll(in entry: TimelineEntry) {
        for change in entry.changes where change.status == .pending || change.status == .partiallyReverted {
            revert(change)
        }
    }

    // MARK: - 事件处理

    private func handle(_ events: [ClientEvent]) {
        for event in events {
            switch event {
            case .sessionUpdate(let id, let update):
                guard sessionId == nil || sessionId == id else { continue }
                lastActivity = .now
                handle(update)
            case .authStatus:
                break   // 不展示账号状态:登录完全由本机 claude 管理
            case .stderr(let text):
                lastActivity = .now
                log.debug("Agent stderr", ["text": LogRedactor.truncate(text, limit: 1000)])
                diagnostics.append(text)
                if diagnostics.count > 200 { diagnostics.removeFirst(diagnostics.count - 200) }
            case .closed(let code):
                handleClosed(code: code)
            case .malformed, .notification:
                break
            }
        }
    }

    private func handle(_ update: SessionUpdate) {
        switch update {
        case .availableCommands(let commands): availableCommands = commands
        case .configOptions(let options): configOptions = options
        case .currentMode(let modeId):
            if let index = configOptions.firstIndex(where: { $0.category == "mode" }) {
                configOptions[index].currentValue = .string(modeId)
            }
        case .sessionInfo(let title, _): if let title { sessionTitle = title }
        case .usage(let value): usage = value
        default: timeline.apply(update)
        }
    }

    private func handleClosed(code: Int32?) {
        guard !isShuttingDown else { return }
        log.error("Agent 进程意外退出", ["code": code.map(String.init) ?? "-", "lastStderr": LogRedactor.truncate(diagnostics.suffix(3).joined(separator: " | "), limit: 600)])
        cancelPendingPrompts()
        timeline.finishStreaming()
        isRunning = false
        let detail = diagnostics.suffix(3).joined(separator: "\n")
        phase = .failed("Agent 进程已退出(代码 \(code.map(String.init) ?? "未知"))。\(detail)")
        client = nil
        supervisor = nil
        sessionId = nil
    }

    // MARK: - 关闭

    private func shutdownProcess() {
        for task in pumpTasks { task.cancel() }
        pumpTasks = []
        connectTask?.cancel()
        connectTask = nil
        promptTask?.cancel()
        watchdogTask?.cancel()
        watchdogTask = nil
        bridge?.stop()
        bridge = nil
        let supervisor = supervisor
        self.supervisor = nil
        client = nil
        sessionId = nil
        if let supervisor { Task { await supervisor.stop() } }
    }

    /// 把运行/待处理状态同步给注意力中心。
    private func publishAttention() {
        guard !isShuttingDown else { return }
        attention.update(
            id: uid,
            title: sessionTitle ?? workspace.lastPathComponent,
            project: workspace.lastPathComponent,
            workspacePath: workspace.path,
            sessionId: sessionId,
            running: isRunning,
            needsInput: !pendingPermissions.isEmpty || !pendingElicitations.isEmpty
        )
    }

    /// 记录最近会话(有会话 ID 与标题时)。
    private func recordRecent() {
        guard !isShuttingDown, let sessionId, let title = sessionTitle, !title.isEmpty else { return }
        RecentStore.record(RecentSession(workspacePath: workspace.path, sessionId: sessionId, title: title, date: Date()))
    }

    /// 关闭窗口时调用:终止 Agent 子进程。
    public func shutdown() {
        log.info("关闭会话")
        isShuttingDown = true
        attention.sessionClosed(uid)
        cancelPendingPrompts()
        for session in terminals.values { session.stop() }
        if let manager = terminalManager { Task { await manager.shutdown() } }
        shutdownProcess()
    }
}
