// @author ixxxxoooo
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
        self.title = request.toolCallRaw["title"]?.stringValue ?? String(localized: "工具调用")
        self.kind = ToolKind(rawOrOther: request.toolCallRaw["kind"]?.stringValue)
        self.tool = ToolCall(json: request.toolCallRaw)
        self.continuation = continuation
    }

    /// 是否为「退出计划模式」请求(`ExitPlanMode`)。
    public var isPlanApproval: Bool { tool.name == "ExitPlanMode" }

    /// 计划文本(Markdown):优先取请求输入中的 `plan`,其次取内容块里的文本。
    public var planText: String? {
        if let plan = tool.rawInput?["plan"]?.stringValue, !plan.isEmpty { return plan }
        let texts = tool.content.compactMap { content -> String? in
            if case .content(let block) = content { return block.plainText }
            return nil
        }
        return texts.isEmpty ? nil : texts.joined(separator: "\n\n")
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
        // 会话提示(notice):压缩、模型回退、Hook 拦截等以结构化提示行呈现,而非夹在回复里的粗体文字
        var caps: [String: JSONValue] = ["session": ["notices": .object([:])]]
        if elicitation { caps["elicitation"] = ["form": .object([:]), "url": .object([:])] }
        return caps
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
    /// 实际使用的描述符
    public private(set) var activeDescriptor: AgentDescriptor
    /// 用户在界面中选中的文字(Bridge 的 get_selection 读取)
    public var selectedText: String?
    /// 系统通知发送器(由应用层注入,Bridge 的 notify 使用)
    public var notifier: (@MainActor (String, String) -> Void)?
    var bridge: BridgeServer?
    var mcpServers: [MCPServerConfig] = []
    public let timeline = TimelineStore()

    public private(set) var phase: SessionPhase = .idle
    /// 连接过程中的补充说明(如「正在安装适配器」);连接结束后为 nil
    public private(set) var connectNote: String?
    public private(set) var isRunning = false {
        didSet {
            guard isRunning != oldValue else { return }
            publishAttention()
            if !isRunning, pendingMappingRefresh { refreshModelMapping() }
        }
    }
    /// 当前轮次开始时间(用于等待文案的计时;不运行时为空)。
    public private(set) var turnStartedAt: Date?
    /// 输入栏上方任务坞:用户选中的分区与是否收起面板(按会话保存)。
    public var dockSelection: ComposerDockSection?
    public var dockHidden = false
    public private(set) var agentName: String
    public private(set) var configOptions: [SessionConfigOption] = []
    public private(set) var availableCommands: [AvailableCommand] = []
    public private(set) var usage: UsageUpdate?
    /// 上下文分类明细(`/context` 探测结果;未探测或 Agent 不支持时为 nil)。
    public private(set) var contextUsage: ContextUsage?
    /// 正在探测上下文明细:非 nil 时拦截消息分片(按 messageId 累积),不进入时间线。
    private var contextProbeChunks: [String: String]?
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
    /// 连接完成后随排队消息一起发送的图片
    @ObservationIgnored private var queuedImages: [ImageAttachment] = []
    /// 输入框草稿
    public var draft = ""
    /// 输入框中待发送的图片附件
    public var attachments: [ImageAttachment] = []
    /// 本轮结束后依次发送的排队消息
    public private(set) var followUps: [QueuedMessage] = []
    /// 当前 `/goal` 目标(客户端根据命令推断;适配器不向普通客户端推送结构化目标)
    public private(set) var goal: GoalState?
    /// 客户端接管命令的执行回调(由应用层打开设置页、面板等)
    @ObservationIgnored public var onLocalCommand: (@MainActor (LocalCommand) -> Void)?
    /// 本机 Skills/自定义命令目录(用于标注来源与连接前兜底)
    @ObservationIgnored public var slashCatalog: (@MainActor () -> [SlashEntry])?
    /// 本机可 @ 提及的子 Agent(名称、说明、来源徽标)
    @ObservationIgnored public var agentCatalog: (@MainActor () -> [(name: String, summary: String, badge: String)])?
    /// 每次发布或回退改动汇总时自增;编辑器据此刷新「Agent 改动」行标记。
    public private(set) var changesRevision = 0
    /// Agent 完成一次文件编辑时回调(用于「跟随 Agent」)。
    @ObservationIgnored public var onAgentEdit: ((AgentEdit) -> Void)?
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
            var tools = await Toolchain.shared.resolve()
            guard let self else { return }
            // 应用包未内置适配器时自动安装,用户无需手动运行脚本
            if descriptor.kind == .claudeACP, tools.adapterEntry == nil, tools.nodePath != nil {
                self.connectNote = String(localized: "正在安装 Claude Code 适配器(仅首次需要,约几十秒)…")
                do {
                    tools = try await Toolchain.shared.ensureAdapter(tools)
                } catch {
                    self.log.error("自动安装适配器失败", error: error, ["agent": descriptor.id, "ms": "\(OMLogger.milliseconds(since: connectStart))"])
                    self.connectNote = nil
                    self.connectTask = nil
                    self.phase = .failed(error.localizedDescription)
                    return
                }
                self.connectNote = nil
            }
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
                let prepared = await self.prepareMCPServers(registry: registry, environment: tools.environment)
                self.mcpServers = prepared.servers
                self.bridge = prepared.bridge
                let setup = try await client.newSession(cwd: cwd, mcpServers: prepared.servers, meta: self.effectiveMeta())
                self.sessionId = setup.sessionId
                self.configOptions = setup.configOptions
                self.phase = .ready
                self.startMappingObserver()
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
                self.phase = .failed(error.localizedDescription)
            }
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

    /// 发送消息。连接未就绪时排队,就绪后自动发送;运行中则引导进当前轮次(Agent 不支持时排到本轮结束后)。
    /// - Parameters:
    ///   - text: 文本
    ///   - images: 图片附件
    ///   - afterTurn: 为 true 时即使正在运行也排到本轮结束后发送(⌘Return)
    ///   - bypassLocal: 为 true 时不解析客户端命令,原样交给 Agent(如 `/mcp` 的会话内状态)
    public func send(_ text: String, images: [ImageAttachment] = [], afterTurn: Bool = false, bypassLocal: Bool = false) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !images.isEmpty else { return }
        // 客户端接管的命令不发给 Agent
        if images.isEmpty, !bypassLocal, let command = LocalCommands.parse(trimmed) {
            perform(command)
            return
        }
        if isRunning {
            if !afterTurn, canSteer, ClientPrefs.runningSendMode() == .steer {
                steer(trimmed, images: images)
            } else {
                enqueueFollowUp(trimmed, images: images)
            }
            return
        }
        switch phase {
        case .ready:
            start(prompt: trimmed, images: images)
        case .idle, .failed:
            queuedPrompt = trimmed
            queuedImages = images
            connect()
        case .connecting:
            queuedPrompt = trimmed
            queuedImages = images
        }
    }

    /// 把命令原样交给 Agent 执行(跳过客户端命令解析)。
    /// - Parameter command: 如 `/mcp reconnect github`
    public func sendToAgent(_ command: String) {
        send(command, bypassLocal: true)
    }

    /// 草稿发送便捷方法(连同图片附件)。
    /// - Parameter afterTurn: 运行中是否排到本轮结束后
    public func sendDraft(afterTurn: Bool = false) {
        let text = draft
        let images = attachments
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty else { return }
        draft = ""
        attachments = []
        send(text, images: images, afterTurn: afterTurn)
    }

    private func flushQueuedPrompt() {
        guard let queued = queuedPrompt else { return }
        let images = queuedImages
        queuedPrompt = nil
        queuedImages = []
        start(prompt: queued, images: images)
    }

    // MARK: - 图片附件

    /// 是否可以添加图片:Agent 声明支持图片提示;连接中/失败时能力尚未确定,先允许添加(连上后仍不支持则在发送前提示)。
    public var canAttachImages: Bool { phase != .ready || capabilities.imagePrompts }

    /// 添加图片附件;超过大小上限或 Agent 不支持时给出提示。
    /// - Parameter image: 图片
    public func addAttachment(_ image: ImageAttachment) {
        guard canAttachImages else {
            timeline.appendNotice(ChatL10n.t("当前 Agent 不支持图片输入,图片未添加。"), severity: "warning")
            return
        }
        guard image.data.count <= ImageAttachment.maxBytes else {
            timeline.appendNotice(String(localized: "图片太大(上限 \(ImageAttachment.maxBytes / 1024 / 1024) MB),已忽略:\(image.name)"), isError: true)
            return
        }
        guard attachments.count < 8 else {
            timeline.appendNotice(ChatL10n.t("一条消息最多附带 8 张图片。"), isError: true)
            return
        }
        attachments.append(image)
    }

    /// 移除图片附件。
    /// - Parameter id: 附件 ID
    public func removeAttachment(_ id: UUID) {
        attachments.removeAll { $0.id == id }
    }

    // MARK: - 运行中引导与排队

    /// 运行中是否可以把消息引导进当前轮次。
    public var canSteer: Bool { capabilities.canSteer && phase == .ready && sessionId != nil && client != nil }

    /// 把消息作为引导注入正在进行的轮次(`_session/steering`);注入失败则转为排队。
    private func steer(_ text: String, images: [ImageAttachment]) {
        guard let client, let sessionId else { return }
        let blocks = promptBlocks(text, images: images)
        log.info("运行中引导", ["turn": "\(turnNumber)", "chars": "\(text.count)"])
        Task { [weak self] in
            do {
                let outcome = try await client.steer(sessionId: sessionId, content: blocks)
                guard let self else { return }
                if outcome == "injected" {
                    self.timeline.appendUser(text, attachments: images, steered: true)
                } else {
                    // 轮次恰好已结束:作为普通消息排队/发送
                    self.log.info("引导未注入,改为排队", ["outcome": outcome])
                    self.enqueueFollowUp(text, images: images)
                    if !self.isRunning { self.flushNextFollowUp() }
                }
            } catch {
                self?.log.error("引导失败,改为排队", error: error)
                self?.enqueueFollowUp(text, images: images)
            }
        }
    }

    /// 加入排队队列(本轮正常结束后依次发送)。
    public func enqueueFollowUp(_ text: String, images: [ImageAttachment] = []) {
        followUps.append(QueuedMessage(text: text, images: images))
    }

    /// 从队列移除。
    /// - Parameter id: 排队消息 ID
    public func removeFollowUp(_ id: UUID) {
        followUps.removeAll { $0.id == id }
    }

    /// 把某条排队消息取回输入框编辑(文字追加到草稿,图片并入附件),并从队列移除。
    /// - Parameter id: 排队消息 ID
    public func editFollowUp(_ id: UUID) {
        guard let item = followUps.first(where: { $0.id == id }) else { return }
        followUps.removeAll { $0.id == id }
        draft = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? item.text : draft + "\n" + item.text
        attachments.append(contentsOf: item.images)
    }

    /// 立即发送某条排队消息:运行中引导注入,空闲时直接发送。
    /// - Parameter id: 排队消息 ID
    public func sendFollowUpNow(_ id: UUID) {
        guard let item = followUps.first(where: { $0.id == id }) else { return }
        followUps.removeAll { $0.id == id }
        send(item.text, images: item.images)
    }

    /// 轮次结束后发送队列中的下一条。
    private func flushNextFollowUp() {
        guard !isRunning, phase == .ready, !followUps.isEmpty else { return }
        let next = followUps.removeFirst()
        send(next.text, images: next.images)
    }

    // MARK: - 客户端命令

    /// 执行客户端接管的命令;需要界面的动作交给 `onLocalCommand`。
    /// - Parameter command: 命令
    public func perform(_ command: LocalCommand) {
        switch command {
        case .newConversation:
            newConversation()
        case .help:
            timeline.appendNotice(ChatL10n.t("命令帮助"), detail: LocalCommands.helpMarkdown(agentCommandCount: availableCommands.count))
        case .status:
            timeline.appendNotice(ChatL10n.t("当前状态"), detail: statusMarkdown())
        case .rename(let name):
            if name.isEmpty {
                timeline.appendNotice(ChatL10n.t("用法:`/rename 新名称`"), severity: "warning")
            } else {
                rename(to: name)
            }
        case .setModel(let name):
            switchModel(named: name)
        case .accountNotice:
            timeline.appendNotice(ChatL10n.t("账号登录由本机 `claude` 管理"), detail: String(localized: "OhMyAgent 不处理登录/登出。请在终端运行 `claude`,执行 `/login` 或 `/logout`。"))
        case .modelMenu:
            timeline.appendNotice(ChatL10n.t("当前模型"), detail: modelListMarkdown())
        case .exportTranscript, .settings, .extensions, .mcpPanel, .history:
            if let onLocalCommand {
                onLocalCommand(command)
            } else {
                timeline.appendNotice(ChatL10n.t("当前窗口不支持该命令。"), severity: "warning")
            }
        }
    }

    /// 重命名当前会话:标题写入客户端偏好并刷新历史列表。
    /// - Parameter title: 新标题
    public func rename(to title: String) {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let sessionId else { return }
        ClientPrefs.setSessionTitle(clean, for: sessionId)
        sessionTitle = clean
        history = history.map { item in
            var copy = item
            if copy.sessionId == sessionId { copy.title = clean }
            return copy
        }
        timeline.appendNotice(String(localized: "会话已重命名为「\(clean)」。"))
    }

    /// 按名称(值或显示名,不区分大小写,支持前缀)切换模型。
    private func switchModel(named name: String) {
        guard let option = option(category: "model") else {
            timeline.appendNotice(ChatL10n.t("当前 Agent 没有可切换的模型。"), severity: "warning")
            return
        }
        let needle = name.lowercased()
        let match = option.options.first { $0.value.lowercased() == needle || $0.name.lowercased() == needle }
            ?? option.options.first { $0.value.lowercased().contains(needle) || $0.name.lowercased().contains(needle) }
        guard let match else {
            let names = option.options.map { "`\($0.value)`" }.joined(separator: String(localized: "、"))
            timeline.appendNotice(String(localized: "没有名为「\(name)」的模型。"), detail: String(localized: "可选:\(names)"), severity: "warning")
            return
        }
        setConfigOption(option.id, value: match.value)
        timeline.appendNotice(String(localized: "模型已切换为 \(match.name)。"))
    }

    /// `/model` 无参数时的模型列表。
    private func modelListMarkdown() -> String {
        guard let option = option(category: "model") else { return String(localized: "当前 Agent 没有可切换的模型。") }
        let lines = option.options.map { item in
            "- \(item.value == option.currentValue.stringValue ? "**" : "")`\(item.value)` \(item.name)\(item.value == option.currentValue.stringValue ? String(localized: "**(当前)") : "")"
        }
        return ([String(localized: "用 `/model <名称>` 切换,或点输入框下方的模型菜单:"), ""] + lines).joined(separator: "\n")
    }

    /// `/status` 文本。
    private func statusMarkdown() -> String {
        var lines: [String] = []
        lines.append(String(localized: "- 工作区:`\(workspace.path)`"))
        if let sessionId { lines.append(String(localized: "- 会话:`\(sessionId)`")) }
        if let model = option(category: "model") {
            lines.append(String(localized: "- 模型:\(model.options.first { $0.value == model.currentValue.stringValue }?.name ?? model.currentValue.stringValue ?? "-")"))
        }
        if let mode = option(category: "mode") {
            lines.append(String(localized: "- 权限模式:\(mode.options.first { $0.value == mode.currentValue.stringValue }?.name ?? mode.currentValue.stringValue ?? "-")"))
        }
        if let main = mappedModels[.main] { lines.append(String(localized: "- 模型映射:\(main.providerName) · \(main.displayName)")) }
        lines.append(String(localized: "- 通告命令:\(availableCommands.count) 个"))
        lines.append(String(localized: "- 运行中引导:\(capabilities.canSteer ? String(localized: "支持") : String(localized: "不支持"));图片输入:\(capabilities.imagePrompts ? String(localized: "支持") : String(localized: "不支持"))"))
        if let goal { lines.append(String(localized: "- 目标:\(goal.objective)\(goal.isActive ? String(localized: "(进行中)") : String(localized: "(已结束)"))")) }
        return lines.joined(separator: "\n")
    }

    // MARK: - 目标

    /// 根据发出的提示推断 `/goal` 状态。
    private func trackGoal(in prompt: String) {
        guard prompt.hasPrefix("/goal") else { return }
        let argument = prompt.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
        if argument.isEmpty { return }   // 单独的 /goal 只是查看状态
        if ["clear", "stop", "off", "reset", "none", "cancel"].contains(argument.lowercased()) {
            goal = nil
        } else {
            goal = GoalState(objective: argument, startedAt: Date(), isActive: true)
        }
    }

    /// 清除目标(发送 `/goal clear`)。
    public func clearGoal() {
        if goal?.isActive == true {
            send("/goal clear")
        }
        goal = nil
    }

    /// 构造提示内容块:文本 + 图片 + 文件引用。
    private func promptBlocks(_ prompt: String, images: [ImageAttachment]) -> [ContentBlock] {
        var blocks: [ContentBlock] = prompt.isEmpty ? [] : [.text(prompt)]
        if capabilities.imagePrompts { blocks += images.map(\.contentBlock) }
        for url in CompletionEngine.mentionedFiles(in: prompt, workspace: workspace, includeDirectories: true) {
            blocks.append(.resourceLink(uri: url.absoluteString, name: url.lastPathComponent, mimeType: nil, title: nil))
        }
        return blocks
    }

    /// 当前会话生效的模型映射(槽位 → 提供商模型);为空表示使用 ~/.claude 的系统默认配置
    public private(set) var mappedModels: [ModelSlot: MappedModel] = [:]
    /// 网关路由键(同一会话重连沿用同一路由令牌)
    @ObservationIgnored private let gatewayKey = "session-\(UUID().uuidString.prefix(8).lowercased())"
    /// 模型映射在运行中被修改:本轮结束后再刷新
    @ObservationIgnored private var pendingMappingRefresh = false
    @ObservationIgnored private var mappingObserver: Task<Void, Never>?
    /// 映射的会话 `_meta`(只含本机网关地址与占位令牌)
    @ObservationIgnored private var providerMeta: JSONValue?
    /// 会话 `_meta`:提供商元数据 + 客户端选项(代理/超时/追加提示词/CLAUDE.md);仅对真实 Claude 通道合并。
    private func effectiveMeta() -> JSONValue? {
        guard activeDescriptor.kind == .claudeACP else { return providerMeta }
        return SessionOptions(defaults: .standard).merged(into: providerMeta ?? defaultGatewayMeta)
    }
    /// 未启用提供商、但 ~/.claude 配置了第三方网关时,仅含「关闭服务端 auto 分类器探测」开关的 `_meta`
    @ObservationIgnored private var defaultGatewayMeta: JSONValue?
    /// 本机网关地址(发送前探测用)
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

    /// 解析模型映射(后台读盘)并注册到本机网关;缺密钥/配置无效时提示并回退到 ~/.claude 默认配置。
    private func resolveProvider(for descriptor: AgentDescriptor) async {
        guard descriptor.kind == .claudeACP else {
            mappedModels = [:]
            providerMeta = nil
            providerURL = nil
            defaultGatewayMeta = nil
            return
        }
        let directory = providerDirectory
        let environment = providerEnvironment
        let initial = await Task.detached(priority: .userInitiated) { () -> Result<ResolvedMapping?, ProviderStorage.ResolveError> in
            do { return .success(try ProviderStorage.resolveMapping(directory: directory, environment: environment)) }
            catch let error as ProviderStorage.ResolveError { return .failure(error) }
            catch { return .success(nil) }
        }.value
        // 注册到本机网关(改写 `_meta`);失败时回退默认配置并提示
        var outcome: Result<ActivatedMapping?, ProviderStorage.ResolveError>
        switch initial {
        case .success(let resolved?):
            do { outcome = .success(try await ProviderBridge.activate(resolved, sessionKey: gatewayKey)) } catch {
                log.error("本机网关不可用", error: error)
                outcome = .failure(.invalid(resolved.main.provider.name, error.localizedDescription))
            }
        case .success(nil): outcome = .success(nil)
        case .failure(let error): outcome = .failure(error)
        }
        switch outcome {
        case .success(let activated?):
            mappedModels = activated.infos
            providerMeta = activated.meta
            providerURL = activated.gatewayURL
            defaultGatewayMeta = nil
            log.info("使用模型映射", ["provider": activated.mainProviderId, "model": activated.mainModel, "slots": "\(activated.infos.count)"])
            for warning in activated.warnings { timeline.appendNotice(warning, severity: "warning") }
        case .success(nil):
            mappedModels = [:]
            providerMeta = nil
            providerURL = nil
            await ProviderBridge.deactivate(sessionKey: gatewayKey)
            // 默认配置:若 ~/.claude/settings.json 里走第三方网关,同样关闭服务端 auto 分类器探测(后台读盘)
            defaultGatewayMeta = await Task.detached(priority: .utility) { () -> JSONValue? in
                let settingsEnv = ModelGateway.loadSettingsEnv()
                return NoticeFilter.gatewayMeta(gateway: ModelGateway.baseURL(settingsEnv: settingsEnv, processEnv: environment), settingsEnv: settingsEnv, processEnv: environment)
            }.value
        case .failure(let error):
            log.warning("模型映射不可用,回退默认配置", ["reason": error.localizedDescription])
            mappedModels = [:]
            providerMeta = nil
            providerURL = nil
            defaultGatewayMeta = nil
            timeline.appendNotice(error.localizedDescription, isError: true)
        }
    }

    private func start(prompt: String, images: [ImageAttachment] = []) {
        guard let client, let sessionId else { return }
        // 非 Claude 通道(测试/脚本化 Agent)无需探测网关,保持同步发送
        guard gatewayChecker != nil || activeDescriptor.kind == .claudeACP else {
            beginTurn(prompt: prompt, images: images, client: client, sessionId: sessionId)
            return
        }
        isRunning = true
        promptTask = Task { [weak self] in
            // 先探测网关:代理没启动时,SDK 会静默重试 10 余次,界面看起来像卡死
            let status = await self?.probeGateway() ?? .notConfigured
            guard let self, self.isRunning else { return }
            if case .unreachable(let url, let reason) = status {
                self.log.error("模型网关不可达,未发送", ["gateway": ModelGateway.origin(of: url), "reason": reason])
                self.abortSend(prompt: prompt, images: images, message: ModelGateway.unreachableMessage(url: url, reason: reason))
                return
            }
            self.beginTurn(prompt: prompt, images: images, client: client, sessionId: sessionId)
        }
    }

    /// 真正开始一轮:写入用户消息、启动看门狗并发出 `session/prompt`。
    private func beginTurn(prompt: String, images: [ImageAttachment], client: ACPClient, sessionId: String) {
        let blocks = promptBlocks(prompt, images: images)
        if !images.isEmpty && !capabilities.imagePrompts {
            timeline.appendNotice(ChatL10n.t("当前 Agent 不支持图片输入,图片未发送。"), severity: "warning")
        }
        trackGoal(in: prompt)
        timeline.appendUser(prompt, attachments: images)
        turnNumber += 1
        turnStart = ContinuousClock.now
        turnStartedAt = Date()
        lastActivity = .now
        log.info("发送提示", ["turn": "\(turnNumber)", "chars": "\(prompt.count)", "blocks": "\(blocks.count)", "images": "\(images.count)"])
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
    private func abortSend(prompt: String, images: [ImageAttachment], message: String) {
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { draft = prompt; attachments = images }
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
                        if let mapped = self.currentMappedModel {
                            // 映射模式下 Claude Code 把上游 401/403 都报成「需要认证」,这里指向真正的原因,而不是让用户去登录 claude
                            self.timeline.appendNotice(String(localized: "「\(mapped.providerName)」拒绝了请求(鉴权或权限):请检查 设置 → 模型提供商 里的 API Key,以及该账号是否有权使用 \(mapped.displayName)。"), isError: true)
                        } else {
                            self.timeline.appendNotice(ChatL10n.t("Claude Code 尚未登录或登录已失效:请在终端运行 claude 完成登录后重试。"), isError: true)
                        }
                    } else {
                        self.timeline.appendNotice(String(localized: "请求失败:\(error.localizedDescription)"), isError: true)
                    }
                }
            } else if reason == .refusal {
                self.timeline.appendNotice(ChatL10n.t("模型拒绝了该请求。"))
            } else if reason == .maxTokens {
                self.timeline.appendNotice(ChatL10n.t("已达到输出上限,回复被截断。"))
            } else if reason == .maxTurnRequests {
                self.timeline.appendNotice(ChatL10n.t("已达到单轮请求上限。"))
            }
            self.publishTurnChanges()
            self.isRunning = false
            self.turnStartedAt = nil
            self.promptTask = nil
            if self.goal?.isActive == true { self.goal?.isActive = false }
            self.refreshHistory()
            // 本轮正常结束才自动发送排队消息;被取消/失败时保留队列,由用户决定
            if error == nil, reason == .endTurn { self.flushNextFollowUp() }
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
        goal = nil
        followUps.removeAll()
        usage = nil
        turnChanges.removeAll()
        turnChangeOrder.removeAll()
        Task { await checkpoints.reset() }
        let servers = mcpServers
        let meta = effectiveMeta()
        Task { [weak self] in
            do {
                let setup = try await client.newSession(cwd: cwd, mcpServers: servers, meta: meta)
                self?.sessionId = setup.sessionId
                self?.configOptions = setup.configOptions
            } catch {
                self?.log.error("创建新对话失败", error: error)
                self?.timeline.appendNotice(String(localized: "创建新对话失败:\(error.localizedDescription)"), isError: true)
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
            let overrides = ClientPrefs.sessionTitleOverrides()
            let sorted = result.sessions.sorted { ($0.updatedAt ?? "") > ($1.updatedAt ?? "") }.map { item -> SessionSummary in
                var copy = item
                if let title = overrides[item.sessionId] { copy.title = title }
                return copy
            }
            self?.history = sorted
        }
    }

    /// 打开历史会话:优先 `session/load`(回放历史),否则 `session/resume`。
    /// - Parameter summary: 会话摘要
    public func openSession(_ summary: SessionSummary) {
        guard let client, phase == .ready, summary.sessionId != sessionId, capabilities.loadSession || capabilities.canResume else { return }
        cancel()
        timeline.reset()
        goal = nil
        followUps.removeAll()
        turnChanges.removeAll()
        turnChangeOrder.removeAll()
        Task { await checkpoints.reset() }
        sessionTitle = ClientPrefs.sessionTitleOverrides()[summary.sessionId] ?? summary.title
        usage = nil
        sessionId = summary.sessionId
        isReplaying = true
        let cwd = workspace.path
        let canLoad = capabilities.loadSession
        let servers = mcpServers
        let meta = effectiveMeta()
        Task { [weak self] in
            do {
                let setup = canLoad
                    ? try await client.loadSession(sessionId: summary.sessionId, cwd: cwd, mcpServers: servers, meta: meta)
                    : try await client.resumeSession(sessionId: summary.sessionId, cwd: cwd, mcpServers: servers, meta: meta)
                self?.configOptions = setup.configOptions.isEmpty ? (self?.configOptions ?? []) : setup.configOptions
            } catch {
                self?.timeline.appendNotice(String(localized: "打开会话失败:\(error.localizedDescription)"), isError: true)
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
        let meta = effectiveMeta()
        Task { [weak self] in
            do {
                let setup = try await client.forkSession(sessionId: sessionId, cwd: cwd, mcpServers: servers, meta: meta)
                self?.sessionId = setup.sessionId
                self?.timeline.appendNotice(ChatL10n.t("已从此处分叉出新会话,后续对话不会影响原会话。"))
                if !setup.configOptions.isEmpty { self?.configOptions = setup.configOptions }
                self?.refreshHistory()
            } catch {
                self?.timeline.appendNotice(String(localized: "分叉失败:\(error.localizedDescription)"), isError: true)
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
            return CompletionEngine.slashItems(query: context.query, agentCommands: availableCommands, entries: slashCatalog?() ?? [])
        case .mention:
            await fileIndex.prepare(root: workspace)
            await fileIndex.waitUntilReady()
            let paths = await fileIndex.search(context.query, limit: 24)
            let dirs = await fileIndex.searchDirectories(context.query, limit: 8)
            let files = paths.map { path in
                CompletionItem(kind: .file, title: (path as NSString).lastPathComponent,
                               subtitle: (path as NSString).deletingLastPathComponent,
                               insertText: CompletionEngine.mentionInsertText(path: path, isDirectory: false))
            }
            let folders = dirs.map { path in
                CompletionItem(kind: .folder, title: (path as NSString).lastPathComponent + "/",
                               subtitle: (path as NSString).deletingLastPathComponent,
                               insertText: CompletionEngine.mentionInsertText(path: path, isDirectory: true))
            }
            let agents = CompletionEngine.agentMentionItems(query: context.query, agents: agentCatalog?() ?? [])
            return agents + files + folders
        }
    }

    /// 循环切换模式(Shift+Tab)。
    public func cycleMode() {
        guard let option = option(category: "mode"), option.options.count > 1 else { return }
        let current = option.currentValue.stringValue
        let index = option.options.firstIndex { $0.value == current } ?? -1
        setConfigOption(option.id, value: option.options[(index + 1) % option.options.count].value)
    }

    // MARK: - 上下文用量明细

    /// 是否正在探测上下文明细。
    public var isProbingContext: Bool { contextProbeChunks != nil }

    /// 当前 Agent 是否支持上下文分类明细(Claude Code 的 `/context`,或 Agent 自行声明了同名命令)。
    public var supportsContextBreakdown: Bool {
        activeDescriptor.kind == .claudeACP || availableCommands.contains { $0.name == "context" }
    }

    /// 刷新上下文分类明细:向 Agent 发送本地命令 `/context` 并解析(不调用模型、不进时间线)。
    ///
    /// 轮次进行中、未连接、已在探测或 Agent 不支持时直接跳过;失败只记日志,不打扰用户。
    public func refreshContextUsage() async {
        guard supportsContextBreakdown, phase == .ready, !isRunning, contextProbeChunks == nil, let client, let sessionId else { return }
        let started = ContinuousClock.now
        contextProbeChunks = [:]
        defer { contextProbeChunks = nil }
        do {
            try await Self.withTimeout(seconds: 8) { _ = try await client.prompt(sessionId: sessionId, content: [.text("/context")]) }
            // 分片经合并器批量投递:先冲刷并稍等,确保输出全部被拦截后再解析
            coalescer?.flush()
            try? await Task.sleep(for: .milliseconds(80))
            let text = (contextProbeChunks ?? [:]).values.max { $0.count < $1.count } ?? ""
            if let parsed = ContextUsageParser.parse(text) {
                contextUsage = parsed
                log.info("上下文明细已刷新", ["session": sessionId, "categories": "\(parsed.categories.count)", "ms": "\(OMLogger.milliseconds(since: started))"])
            } else {
                log.warning("上下文明细解析失败", ["session": sessionId, "chars": "\(text.count)"])
            }
        } catch {
            log.warning("上下文明细探测失败", ["session": sessionId, "error": "\(error)"])
        }
    }

    /// 带超时地执行一个异步操作;超时抛出 `CancellationError`。
    private static func withTimeout(seconds: Double, _ operation: @escaping @Sendable () async throws -> Void) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw CancellationError()
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }

    // MARK: - 模型映射刷新

    /// 当前选中的模型槽位对应的映射模型(未启用映射时为 nil)。
    var currentMappedModel: MappedModel? {
        guard !mappedModels.isEmpty else { return nil }
        let value = option(category: "model")?.currentValue.stringValue ?? "default"
        return ModelSlot(optionValue: value).flatMap { mappedModels[$0] } ?? mappedModels[.main]
    }

    /// 开始监听设置页的模型映射变化(幂等,连接成功后调用)。
    private func startMappingObserver() {
        guard mappingObserver == nil else { return }
        mappingObserver = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .omModelMappingChanged) {
                guard let self else { return }
                self.mappingChanged()
            }
        }
    }

    /// 设置页修改了映射:空闲时立即刷新,运行中等本轮结束。
    func mappingChanged() {
        guard activeDescriptor.kind == .claudeACP, phase == .ready else { return }
        if isRunning { pendingMappingRefresh = true } else { refreshModelMapping() }
    }

    /// 重新解析映射;结果有变化时用新的 `_meta` 恢复同一会话(保留上下文),无法恢复则新建会话。
    /// 运行中、未连接或非 Claude 通道时忽略。
    func refreshModelMapping() {
        guard activeDescriptor.kind == .claudeACP, phase == .ready, !isRunning, let client, let sessionId else { return }
        pendingMappingRefresh = false
        let hadConversation = !timeline.entries.isEmpty
        let canResume = capabilities.canResume
        let cwd = workspace.path
        let servers = mcpServers
        let started = ContinuousClock.now
        let previous = mappedModels
        Task { [weak self] in
            guard let self else { return }
            await self.resolveProvider(for: self.activeDescriptor)
            guard self.mappedModels != previous else { return }
            let meta = self.effectiveMeta()
            let target = self.mappedModels[.main].map { "\($0.providerName) · \($0.displayName)" } ?? ChatL10n.t("系统默认")
            do {
                if hadConversation, canResume {
                    let setup = try await client.resumeSession(sessionId: sessionId, cwd: cwd, mcpServers: servers, meta: meta)
                    if !setup.configOptions.isEmpty { self.configOptions = setup.configOptions }
                    self.timeline.appendNotice(String(localized: "模型映射已更新为 \(target),对话上下文已保留。"))
                } else {
                    try await self.startFreshSession(client: client, cwd: cwd, servers: servers, meta: meta)
                    self.timeline.appendNotice(String(localized: "模型映射已更新为 \(target)。"))
                }
                self.log.info("会话刷新模型映射", ["ms": "\(OMLogger.milliseconds(since: started))"])
            } catch {
                // 恢复失败:退回到新会话,避免卡在半切换状态
                self.log.warning("恢复会话失败,改为新建会话", ["error": "\(error)"])
                do {
                    try await self.startFreshSession(client: client, cwd: cwd, servers: servers, meta: meta)
                    self.timeline.appendNotice(String(localized: "模型映射已更新为 \(target),但之前的对话上下文无法沿用,已开始新会话。"), severity: "warning")
                } catch {
                    self.timeline.appendNotice(String(localized: "刷新模型映射失败:\(error.localizedDescription)"), isError: true)
                }
            }
        }
    }

    /// 用给定 `_meta` 新建会话并替换当前会话 ID。
    private func startFreshSession(client: ACPClient, cwd: String, servers: [MCPServerConfig], meta: JSONValue?) async throws {
        let setup = try await client.newSession(cwd: cwd, mcpServers: servers, meta: meta)
        sessionId = setup.sessionId
        configOptions = setup.configOptions
        contextUsage = nil
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
                self?.timeline.appendNotice(String(localized: "设置失败:\(error.localizedDescription)"), isError: true)
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
        // 计划被批准后,把计划文档留在时间线里,方便回看
        if prompt.isPlanApproval, let plan = prompt.planText,
           let option = prompt.request.options.first(where: { $0.optionId == optionId }),
           option.kind == .allowOnce || option.kind == .allowAlways {
            timeline.appendPlanDoc(plan)
        }
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
            if let notify = onAgentEdit {
                notify(AgentEdit(path: path, firstChangedLine: Self.firstChangedLine(old: before, new: after)))
            }
        }
    }

    /// 一次编辑中第一处改动在新文件里的行号(1 起始)。
    /// - Parameters:
    ///   - old: 编辑前内容(nil 表示新建文件)
    ///   - new: 编辑后内容
    /// - Returns: 首个新增行号;只有删除时返回删除处所在行;内容相同返回 nil
    nonisolated static func firstChangedLine(old: String?, new: String) -> Int? {
        guard let hunk = LineDiff.diff(old: old, new: new).hunks.first else { return nil }
        var lastNew = hunk.newStart - 1
        for line in hunk.lines {
            switch line.kind {
            case .added: return line.newNumber
            case .removed: return max(lastNew + 1, 1)
            case .context: lastNew = line.newNumber ?? lastNew
            }
        }
        return max(hunk.newStart, 1)
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
        changesRevision += 1
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
            case .notFound: change.status = .failed(String(localized: "没有可用的检查点"))
            case .failed(let message): change.status = .failed(message)
            }
            self?.changesRevision += 1
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
        case .sessionInfo(let title, _):
            if let title { sessionTitle = sessionId.flatMap { ClientPrefs.sessionTitleOverrides()[$0] } ?? title }
        case .usage(let value): usage = value
        case .agentMessageChunk(let messageId, let content) where contextProbeChunks != nil:
            // 上下文探测期间的输出属于 `/context` 命令,只累积不展示;适配器可能以不同 messageId 重复发送整份输出
            if case .text(let text) = content { contextProbeChunks?[messageId ?? "default", default: ""] += text }
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
        phase = .failed(String(localized: "Agent 进程已退出(代码 \(code.map(String.init) ?? String(localized: "未知")))。\(detail)"))
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
        mappingObserver?.cancel()
        mappingObserver = nil
        let key = gatewayKey
        Task { await ProviderBridge.deactivate(sessionKey: key) }
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

/// Agent 完成的一次文件编辑。
public struct AgentEdit: Sendable, Equatable {
    /// 文件绝对路径
    public var path: String
    /// 第一处改动所在行(1 起始),无法确定为 nil
    public var firstChangedLine: Int?

    public init(path: String, firstChangedLine: Int?) {
        self.path = path
        self.firstChangedLine = firstChangedLine
    }
}

/// 排队等待发送的消息。
public struct QueuedMessage: Identifiable, Sendable, Hashable {
    public let id = UUID()
    public var text: String
    public var images: [ImageAttachment]

    public init(text: String, images: [ImageAttachment] = []) {
        self.text = text
        self.images = images
    }
}

/// `/goal` 目标状态。
public struct GoalState: Sendable, Equatable {
    public var objective: String
    public var startedAt: Date
    /// 目标仍在推进(所在轮次未结束)
    public var isActive: Bool
}
