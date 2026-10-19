// @author ixxxxoooo
// 会话模型:一个窗口对应一个 SessionModel,独占一个 Agent 子进程与一个 ACP 会话。
// 后台:事件接收与合并;主 actor:只应用合并后的批次。

import ACPKit
import CanvasKit
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

    /// 计划在时间线里对应的计划卡(请求到达时就加入,批准/拒绝后回写状态)。
    public weak var planEntry: TimelineEntry?

    /// Claude Code 把计划写入的文件(`~/.claude/plans/*.md`);请求入参里的 `planFilePath`,没有则为 nil。
    public var planFilePath: String? { tool.rawInput?["planFilePath"]?.stringValue }

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
    /// 声明 `_meta.terminal_output`:Claude Code 的 Bash 输出经 `_meta` 报告,
    /// 本应用据此显示 Agent 终端(含后台命令的实时输出与结束状态)
    public var agentTerminalOutput = true

    public init() {}

    /// 从用户默认值读取。
    public static func load(_ defaults: UserDefaults = .standard) -> ClientFeatures {
        var features = ClientFeatures()
        if defaults.object(forKey: "feature.fileSystem") != nil { features.fileSystem = defaults.bool(forKey: "feature.fileSystem") }
        if defaults.object(forKey: "feature.terminal") != nil { features.terminal = defaults.bool(forKey: "feature.terminal") }
        if defaults.object(forKey: "feature.elicitation") != nil { features.elicitation = defaults.bool(forKey: "feature.elicitation") }
        if defaults.object(forKey: "feature.agentTerminalOutput") != nil { features.agentTerminalOutput = defaults.bool(forKey: "feature.agentTerminalOutput") }
        return features
    }

    /// 声明给 Agent 的额外能力。
    var extraCapabilities: [String: JSONValue] {
        // 会话提示(notice):压缩、模型回退、Hook 拦截等以结构化提示行呈现,而非夹在回复里的粗体文字
        var caps: [String: JSONValue] = ["session": ["notices": .object([:])]]
        if elicitation { caps["elicitation"] = ["form": .object([:]), "url": .object([:])] }
        if agentTerminalOutput { caps["_meta"] = ["terminal_output": true] }
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

    /// 路径解析符号链接后是否位于工作区内。尚不存在的部分沿用最近的已存在祖先目录的真实路径。
    /// - Parameters:
    ///   - path: 要写入的路径
    ///   - root: 工作区根目录
    /// - Returns: 在工作区内(或就是工作区本身)时为 true
    static func isInsideWorkspace(_ path: String, root: String) -> Bool {
        let realRoot = realPath(root)
        let realTarget = realPath(path)
        return realTarget == realRoot || realTarget.hasPrefix(realRoot + "/")
    }

    /// 解析符号链接后的真实路径:从最近的已存在祖先开始解析,再拼回尚不存在的尾部。
    /// 该祖先本身是悬空软链时(`resolvingSymlinksInPath` 不处理),按链接目标继续解析。
    /// - Parameters:
    ///   - path: 路径
    ///   - depth: 已跟随的悬空软链层数(防循环)
    private static func realPath(_ path: String, depth: Int = 0) -> String {
        let fm = FileManager.default
        var existing = URL(fileURLWithPath: path).standardizedFileURL
        var tail: [String] = []
        // 用 lstat 语义判断存在(悬空的软链也算存在,这样会被解析而不是被当作普通的新文件名)
        while (try? fm.attributesOfItem(atPath: existing.path)) == nil, existing.path != "/" {
            tail.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        if !fm.fileExists(atPath: existing.path), depth < 32, let destination = try? fm.destinationOfSymbolicLink(atPath: existing.path) {
            let target = URL(fileURLWithPath: destination, relativeTo: existing.deletingLastPathComponent())
            return realPath(([target.path] + tail).joined(separator: "/"), depth: depth + 1)
        }
        var resolved = existing.resolvingSymlinksInPath()
        for component in tail { resolved.appendPathComponent(component) }
        return resolved.standardizedFileURL.path
    }

    func writeTextFile(sessionId: String, path: String, content: String) async throws {
        // 只允许写入工作区内,防止越权覆盖(按解析符号链接后的真实路径判断,工作区里的软链不能把写入带到外面)
        let root = URL(fileURLWithPath: workspace).standardizedFileURL.path
        let target = URL(fileURLWithPath: path).standardizedFileURL
        guard Self.isInsideWorkspace(path, root: workspace) else {
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
    public private(set) var configOptions: [SessionConfigOption] = [] {
        didSet { if !configOptions.isEmpty { Self.lastConfigOptions[activeDescriptor.id] = configOptions } }
    }
    /// 各 Agent 最近一次拿到的配置选项(模式/模型/思考强度):恢复历史会话时先用它占位,
    /// 避免在 `session/load` 返回前(约 1.5 秒)输入框底部一片空白、随后突然冒出来。
    @MainActor private static var lastConfigOptions: [String: [SessionConfigOption]] = [:]
    public private(set) var availableCommands: [AvailableCommand] = []
    public private(set) var usage: UsageUpdate?
    /// 提示缓存统计(本次打开会话以来各轮的主对话用量;不支持缓存时为 nil)。
    public private(set) var promptCache: PromptCacheStats?
    /// 上下文分类明细(`/context` 探测结果;未探测或 Agent 不支持时为 nil)。
    public private(set) var contextUsage: ContextUsage?
    /// 正在探测上下文明细:非 nil 时拦截消息分片(按 messageId 累积),不进入时间线。
    private var contextProbeChunks: [String: String]?
    public private(set) var sessionTitle: String? { didSet { if sessionTitle != oldValue { recordRecent() } } }
    /// 当前标题的来源(决定自动标题能否覆盖它)
    @ObservationIgnored private var titleSource: TitleSource = .none
    /// 自动标题生成任务(换会话时取消)
    @ObservationIgnored private var titleTask: Task<Void, Never>?
    public private(set) var pendingPermissions: [PermissionPrompt] = [] { didSet { if pendingPermissions.isEmpty != oldValue.isEmpty { publishAttention() } } }
    public private(set) var pendingElicitations: [ElicitationPrompt] = [] { didSet { if pendingElicitations.isEmpty != oldValue.isEmpty { publishAttention() } } }
    /// 终端会话(按终端 ID)
    public internal(set) var terminals: [String: TerminalSession] = [:]
    public private(set) var sessionId: String? { didSet { if sessionId != oldValue { publishAttention(); recordRecent() } } }
    /// 进程内唯一标识(注意力中心与通知使用)
    public let uid = UUID().uuidString
    /// 注意力中心(测试可注入)
    @ObservationIgnored public var attention: AttentionCenter = .shared
    /// 最近一次连接(启动适配器 + 握手 + 新建会话)耗时,用于诊断
    public private(set) var connectDuration: Duration?
    /// 恢复模式的目标会话:连接成功后不创建新会话,直接加载它(见 `prepareRestore`)
    @ObservationIgnored private var restoreTarget: SessionSummary?
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
    /// 输入框草稿(休眠中的会话一开始输入就预唤醒,发送时多半已就绪)
    public var draft = "" {
        didSet { if isHibernated, oldValue.isEmpty, !draft.isEmpty { wake() } }
    }
    /// 输入框中待发送的图片附件
    public var attachments: [ImageAttachment] = []
    /// 本轮结束后依次发送的排队消息
    public private(set) var followUps: [QueuedMessage] = []
    /// 当前 `/goal` 目标(客户端根据命令推断;适配器不向普通客户端推送结构化目标)
    public private(set) var goal: GoalState?
    /// 客户端接管命令的执行回调(由应用层打开设置页、面板等)
    @ObservationIgnored public var onLocalCommand: (@MainActor (LocalCommand) -> Void)?
    /// Agent 提交了计划且计划文件已就绪(参数是对应的计划卡):应用层据此在右侧分屏打开计划标签
    @ObservationIgnored public var onPlanProposed: (@MainActor (TimelineEntry) -> Void)?
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
    /// 需要在标签页中打开的画布(Agent 通过 Bridge 新建画布时设置,应用层消费后置空)
    public var canvasRequest: CanvasOpenRequest?
    /// 画布存储(默认在 Application Support;测试/演示可替换)
    /// 就绪后要切换到的模型名(一次性;`/best-of-n` 使用)
    @ObservationIgnored public var pendingModelName: String?
    /// 「在工作树中运行」开关:开启后首条消息会先创建工作树(界面层处理)
    public var runInWorktree = false
    @ObservationIgnored public var canvasStore = CanvasStore(directory: CanvasStore.defaultDirectory())
    /// 计划文件的全局目录(默认 `~/.claude/plans`;测试可替换)
    @ObservationIgnored public var planDirectory = PlanStore.globalDirectory

    /// 已休眠:Agent 进程已结束以释放内存,时间线/草稿/标题仍在;再次使用时自动唤醒(见 `hibernate()`/`wake()`)
    public private(set) var isHibernated = false
    /// 可以接受操作:已就绪,或休眠中(需要进程的操作会先自动唤醒)。界面上「是否可用」的判断应使用它而不是 `phase == .ready`。
    public var isAvailable: Bool { phase == .ready || isHibernated }
    /// 最近一次使用时间(发送、轮次结束、被切到前台),驻留策略据此决定休眠顺序
    public private(set) var lastUsedAt = Date()
    /// 休眠时记下的会话 ID:唤醒时用 `session/resume` 接回(没有对话内容的会话不记,唤醒即新建)
    @ObservationIgnored private var dormantSessionId: String?
    /// 休眠时记下的配置项取值(权限模式、思考强度等),唤醒后与恢复出的取值不同则重新应用
    @ObservationIgnored private var dormantConfig: [String: String] = [:]
    /// 唤醒就绪后依次执行的动作(休眠期间收到的设置、打开会话等请求)
    @ObservationIgnored private var wakeActions: [@MainActor () -> Void] = []

    private var supervisor: AgentSupervisor?
    private var client: ACPClient?
    private var coalescer: EventCoalescer?
    @ObservationIgnored private let eventBarrier = EventBarrier()
    private var pumpTasks: [Task<Void, Never>] = []
    private var promptTask: Task<Void, Never>?
    private var connectTask: Task<Void, Never>?
    private var isShuttingDown = false
    private var terminalManager: TerminalManager?
    private let checkpoints = CheckpointStore()
    private var turnNumber = 0
    private var turnStart: ContinuousClock.Instant?
    /// 本回合性能统计:首个输出耗时(TTFT)、输出分片数、工具调用数。
    private var turnFirstChunkMs: Int?
    private var turnChunks = 0
    private var turnToolCalls = 0
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
            let manager = TerminalManager(workspace: cwd, environment: { environment }, sandbox: { ClientPrefs.terminalSandboxConfig() }, onCreated: { [weak self] created in
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
                // 恢复模式:目标是打开一个已有会话时跳过 session/new(不创建空会话),握手后直接 session/load
                let restoring = self.restoreTarget
                var wokeFrom: String?
                if restoring == nil {
                    if let dormant = self.dormantSessionId {
                        wokeFrom = try await self.resumeDormant(dormant, client: client, methods: result.authMethods, servers: prepared.servers)
                    } else {
                        let setup = try await self.newSessionAuthenticating(client: client, methods: result.authMethods, servers: prepared.servers)
                        self.sessionId = setup.sessionId
                        self.configOptions = setup.configOptions
                        self.applyPreferredMode()
                    }
                }
                self.restoreTarget = nil
                self.isHibernated = false
                self.dormantSessionId = nil
                self.phase = .ready
                self.startMappingObserver()
                self.connectDuration = connectStart.duration(to: .now)
                self.log.info("Agent 已就绪", ["agent": result.agentName, "ms": "\(OMLogger.milliseconds(since: connectStart))", "mcpServers": "\(prepared.servers.count)", "bridge": prepared.bridge == nil ? "off" : "on", "restore": restoring == nil ? "no" : "yes"])
                self.connectTask = nil
                self.refreshHistory()
                if wokeFrom != nil { self.reapplyDormantConfig() }
                self.runWakeActions()
                if let restoring {
                    // 排队消息等会话回放完成后再发(openSession 末尾会 flush)
                    self.openSession(restoring, force: true)
                } else {
                    await self.applyPendingModel(client: client)
                    self.flushQueuedPrompt()
                }
            } catch {
                self.log.error("连接 Agent 失败", error: error, ["agent": descriptor.id, "ms": "\(OMLogger.milliseconds(since: connectStart))", "waking": self.isHibernated ? "yes" : "no"])
                await supervisor.stop()
                await manager.shutdown()
                if self.terminalManager === manager { self.terminalManager = nil }
                self.bridge?.stop()
                self.bridge = nil
                self.connectTask = nil
                // 唤醒失败:排队的动作(打开/分叉/删除等)已失去上下文,丢弃;休眠标记与会话 ID 保留,重新连接时再尝试接回
                if !self.wakeActions.isEmpty {
                    self.log.warning("唤醒失败,丢弃排队动作", ["count": "\(self.wakeActions.count)"])
                    self.wakeActions = []
                }
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    /// 建会话;若 Agent 要求先登录(如 Antigravity),按其声明的认证方式调用 `authenticate` 后重试一次。
    /// - Parameters:
    ///   - client: ACP 客户端
    ///   - methods: `initialize` 返回的认证方式
    ///   - servers: MCP 服务器配置
    private func newSessionAuthenticating(client: ACPClient, methods: [AuthMethod], servers: [MCPServerConfig]) async throws -> SessionSetup {
        let cwd = workspace.path
        do {
            let setup = try await client.newSession(cwd: cwd, mcpServers: servers, additionalDirectories: additionalDirectories, meta: effectiveMeta())
            EmptySessionRegistry.hide(setup.sessionId)
            return setup
        } catch let error as JSONRPCError where error.isAuthRequired {
            guard let method = methods.first else { throw error }
            log.info("Agent 需要登录,开始认证", ["agent": descriptor.id, "method": method.id])
            timeline.appendNotice(String(localized: "「\(descriptor.name)」需要登录,正在按「\(method.name)」认证…"), detail: method.description)
            do {
                try await client.authenticate(methodId: method.id)
            } catch {
                log.error("认证失败", error: error, ["agent": descriptor.id, "method": method.id])
                throw AuthenticationFailure(agent: descriptor.name, reason: error.localizedDescription)
            }
            let setup = try await client.newSession(cwd: cwd, mcpServers: servers, additionalDirectories: additionalDirectories, meta: effectiveMeta())
            EmptySessionRegistry.hide(setup.sessionId)
            return setup
        }
    }

    /// 本轮是否记录了该文件的改动。
    public func hasTurnChange(at path: String) -> Bool {
        guard let item = turnChanges[path] else { return false }
        return item.original != item.current
    }

    /// 本轮记录的该文件改动(原始内容与当前内容)。
    public func turnChange(at path: String) -> (original: String?, current: String)? {
        turnChanges[path]
    }

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    /// 重新连接(失败后重试)。
    public func reconnect() {
        shutdownProcess(keepingSession: isHibernated)
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
        let barrier = eventBarrier
        let reader = Task.detached(priority: .userInitiated) {
            for await event in client.events {
                // 屏障:只做登记,不进入时间线
                if case .notification(let method, let params) = event, method == ACPConnection.barrierMethod {
                    if let token = params?["token"]?.stringValue { barrier.signal(token) }
                    continue
                }
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
                EventCoalescer.backlog.consumed(batch.count)
                guard let self else { return }
                let span = Log.perf.span("事件批处理", warnMs: 16, quiet: true, ["events": "\(batch.count)"])
                self.handle(batch)
                coalescer.markApplied(batch.count)
                span.end()
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

    /// 是否为最后一条用户消息(只有它可以「重试」覆盖原回答)。
    /// - Parameter entry: 时间线里的用户消息条目
    /// - Returns: 条目是用户消息且其后没有更新的用户消息
    public func isLastUserMessage(_ entry: TimelineEntry) -> Bool {
        entry.kind == .user && timeline.entries.last(where: { $0.kind == .user })?.id == entry.id
    }

    /// 重试最后一条用户消息:丢弃该消息及其后的旧回答,再用同样的文本与图片重新发送。
    /// - Parameter entry: 要重试的用户消息(必须是最后一条;运行中无效)
    public func retryUserMessage(_ entry: TimelineEntry) {
        guard !isRunning, isLastUserMessage(entry), let index = timeline.entries.firstIndex(where: { $0.id == entry.id }) else { return }
        let prompt = entry.displayText
        let images = entry.attachments
        timeline.reset(with: Array(timeline.entries[..<index]))
        send(prompt, images: images)
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
        if isRunning {
            // 用户明确点了「引导」:不受「运行中发送方式」偏好影响;Agent 不支持引导时保留在队列里
            guard canSteer else { return }
            followUps.removeAll { $0.id == id }
            steer(item.text, images: item.images)
            return
        }
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
        case .unsupported(let name):
            timeline.appendNotice(ChatL10n.f("`/%@` 在 OhMyAgent 里不可用", name), detail: ClaudeBuiltinCommands.unsupported[name], severity: "warning")
        case .explore(let question):
            if question.isEmpty {
                timeline.appendNotice(ChatL10n.t("用法:`/explore 要弄清的问题`"), severity: "warning")
            } else {
                send(LocalCommands.explorePrompt(question), bypassLocal: true)
            }
        case .modelMenu:
            timeline.appendNotice(ChatL10n.t("当前模型"), detail: modelListMarkdown())
        case .exportTranscript, .settings, .extensions, .mcpPanel, .history, .worktree, .applyWorktree, .deleteWorktree, .bestOfN:
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
        titleTask?.cancel()
        titleSource = .manual
        sessionTitle = clean
        history = history.map { item in
            var copy = item
            if copy.sessionId == sessionId { copy.title = clean }
            return copy
        }
        timeline.appendNotice(String(localized: "会话已重命名为「\(clean)」。"))
    }

    /// 应用外部(侧栏)对某个会话的重命名:同步历史列表里的标题;若正是当前会话,标题一并更新。
    /// 标题本身由调用方写入 `ClientPrefs`。
    /// - Parameters:
    ///   - title: 新标题
    ///   - target: 被重命名的会话 ID
    public func applyRenamedTitle(_ title: String, sessionId target: String) {
        // 只在确实包含该会话时才改写历史:避免空列表触发 onHistoryChanged 把侧栏缓存冲掉
        if history.contains(where: { $0.sessionId == target }) {
            history = history.map { item in
                var copy = item
                if copy.sessionId == target { copy.title = title }
                return copy
            }
        }
        if target == sessionId {
            titleTask?.cancel()
            titleSource = .manual
            sessionTitle = title
        }
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
        // 切换成功后由 setConfigOption 在时间线插入「由 X 切换为 Y」分割线
        setConfigOption(option.id, value: match.value)
    }

    /// 就绪后、发出排队消息之前切到 `pendingModelName`(`/best-of-n` 为每个工作树会话指定不同模型);找不到时保持默认并提示。
    /// - Parameter client: 已连接的客户端
    private func applyPendingModel(client: ACPClient) async {
        guard let name = pendingModelName, !name.isEmpty else { return }
        pendingModelName = nil
        guard let option = option(category: "model"), let sessionId else { return }
        let needle = name.lowercased()
        let match = option.options.first { $0.value.lowercased() == needle || $0.name.lowercased() == needle }
            ?? option.options.first { $0.value.lowercased().contains(needle) || $0.name.lowercased().contains(needle) }
        guard let match else {
            timeline.appendNotice(String(localized: "没有名为「\(name)」的模型,使用默认模型。"), severity: "warning")
            return
        }
        do {
            let updated = try await client.setConfigOption(sessionId: sessionId, configId: option.id, value: .string(match.value))
            if !updated.isEmpty { configOptions = updated }
        } catch {
            log.warning("切换待定模型失败", ["model": name, "error": error.localizedDescription])
        }
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
        // `@browser`:附一个隐藏的提示块(用户看到的消息不变;历史重放时由时间线隐藏)
        if BrowserMention.isMentioned(in: prompt) { blocks.append(.text(BrowserMention.hint(servers: browserHintServers))) }
        return blocks
    }

    /// `@browser` 提示块里给出的开发服务器(发送前异步检测)
    @ObservationIgnored private var browserHintServers: [DevServer] = []

    /// 当前会话生效的模型映射(槽位 → 提供商模型);为空表示使用 ~/.claude 的系统默认配置
    public private(set) var mappedModels: [ModelSlot: MappedModel] = [:]
    /// 已配置的映射(不论是否启用):输入框据此同时列出「Claude Code 原生」与「自定义映射」两组
    public private(set) var configuredMappings: [ModelSlot: MappedModel] = [:]
    /// 切换来源后待应用的模型选项(会话刷新完成后再设置)
    @ObservationIgnored private var pendingModelSelection: (optionId: String, value: String)?
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
        var options = SessionOptions(defaults: .standard)
        // 直连官方 API(无模型映射、~/.claude 也没配第三方网关)时,「自动」默认启用 MCP 工具按需加载:
        // Bridge 的十几个工具定义不再每轮随请求发送,用到时由模型搜索加载;第三方网关未必支持 tool_reference,保持 Claude Code 默认
        if options.mcpToolSearch == .auto, providerMeta == nil, defaultGatewayMeta == nil { options.mcpToolSearch = .on }
        let extras = [extraSystemPrompt, additionalDirectoriesNote, ChartPrompt.text].compactMap { $0 }.filter { !$0.isEmpty }
        if !extras.isEmpty {
            options.appendPrompt = ([options.appendPrompt.trimmingCharacters(in: .whitespacesAndNewlines)] + extras).filter { !$0.isEmpty }.joined(separator: "\n\n")
        }
        let merged = options.merged(into: providerMeta ?? defaultGatewayMeta)
        guard isPlainChat else { return merged }
        // 无模型映射时才并入 settings.json 的 env;映射会话的变量已由提供商 `_meta` 给全
        let settingsEnv = providerMeta == nil ? plainChatSettingsEnv : [:]
        return SessionOptions.plainChat(merged, systemPrompt: options.appendPrompt, settingsEnv: settingsEnv)
    }
    /// 纯文字会话(会话区):不带工具、MCP、CLAUDE.md、技能与 Claude Code 系统提示,只当普通聊天;须在连接前设置。
    public var isPlainChat = false
    /// 纯文字会话需要手动并入的 `~/.claude/settings.json` 的 `env`(后台读盘,见 `resolveProvider`)。
    @ObservationIgnored private var plainChatSettingsEnv: [String: String] = [:]
    /// 额外追加到系统提示末尾的文本(会话区用它约束为纯文字问答);须在连接前设置。
    public var extraSystemPrompt: String?
    /// 多文件夹工作区里除主目录(`workspace`)之外的附加文件夹(绝对路径);须在连接前设置,
    /// 对已建立的 ACP 会话不生效(协议不支持运行中变更)。
    public var additionalDirectories: [String] = []
    /// 引擎不支持 `additionalDirectories` 能力时的兜底:把附加文件夹写进系统提示,让 Agent 知道它们的存在。
    /// - Returns: 无附加文件夹或引擎原生支持时为 nil
    public var additionalDirectoriesNote: String? {
        guard !additionalDirectories.isEmpty, !capabilities.additionalDirectories else { return nil }
        let list = additionalDirectories.map { "- \($0)" }.joined(separator: "\n")
        return String(localized: "本工作区除当前目录外还包含以下文件夹,需要时可以用绝对路径读取、搜索与修改其中的文件:") + "\n" + list
    }
    /// 未启用提供商、但 ~/.claude 配置了第三方网关时,仅含「关闭服务端 auto 分类器探测」开关的 `_meta`
    @ObservationIgnored private var defaultGatewayMeta: JSONValue?
    /// 本机网关地址(发送前探测用)
    @ObservationIgnored private var providerURL: URL?

    /// 轻量任务(提交说明等)可用的本机网关地址与小模型别名;当前没有经网关的提供商映射时为 nil。
    public var utilityGateway: (url: URL, alias: String)? {
        guard let url = providerURL, mappedModels[.haiku] != nil || mappedModels[.main] != nil else { return nil }
        return (url, (mappedModels[.haiku] != nil ? ModelSlot.haiku : ModelSlot.main).alias)
    }
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
        if isPlainChat { plainChatSettingsEnv = await Task.detached(priority: .utility) { ModelGateway.loadSettingsEnv() }.value }
        guard descriptor.kind == .claudeACP else {
            mappedModels = [:]
            providerMeta = nil
            providerURL = nil
            defaultGatewayMeta = nil
            return
        }
        let directory = providerDirectory
        let environment = providerEnvironment
        configuredMappings = await Task.detached(priority: .userInitiated) { ProviderStorage.configuredInfos(directory: directory) }.value
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
            if BrowserMention.isMentioned(in: prompt) { self.browserHintServers = await DevServerDetector.detect(workspace: self.workspace.path) }
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
        EmptySessionRegistry.unhide(sessionId)
        turnNumber += 1
        if sessionTitle == nil, titleSource == .none { startAutoTitle(for: prompt, sessionId: sessionId) }
        turnStart = ContinuousClock.now
        turnFirstChunkMs = nil
        turnChunks = 0
        turnToolCalls = 0
        turnStartedAt = Date()
        lastUsedAt = Date()
        lastActivity = .now
        log.info("发送提示", ["turn": "\(turnNumber)", "chars": "\(prompt.count)", "blocks": "\(blocks.count)", "images": "\(images.count)"])
        turnChanges.removeAll()
        turnChangeOrder.removeAll()
        isRunning = true
        startWatchdog()
        promptTask = Task { [weak self] in
            do {
                let result = try await client.promptWithUsage(sessionId: sessionId, content: blocks)
                self?.finishTurn(reason: result.reason, usage: result.usage, error: nil)
            } catch {
                self?.finishTurn(reason: nil, usage: nil, error: error)
            }
        }
    }

    /// 首条消息后的自动标题:先用首句截取立刻给出临时标题,再异步经本机网关用小模型生成短标题覆盖。
    /// 模型可在设置里单独指定(`UtilityTask.title`),也可关闭只保留截取标题;
    /// 仅在没有更高优先级来源(手动、适配器)时生效;失败只记日志并保留截取标题。
    private func startAutoTitle(for prompt: String, sessionId: String) {
        if let fallback = TitleGenerator.fallbackTitle(from: prompt) {
            applyAutoTitle(fallback, source: .truncated, sessionId: sessionId)
        }
        let choice = UtilityModels.choice(for: .title)
        guard choice != .off else { return }
        let sessionGateway = utilityGateway
        titleTask?.cancel()
        titleTask = Task { [weak self] in
            guard let endpoint = await UtilityModels.endpoint(for: choice, fallback: sessionGateway), !Task.isCancelled else { return }
            guard let title = await TitleGenerator.generate(gateway: endpoint.url, model: endpoint.alias, userText: prompt), !Task.isCancelled else { return }
            self?.applyAutoTitle(title, source: .generated, sessionId: sessionId)
        }
    }

    /// 应用自动标题:只在来源优先级不低于当前来源、且仍是同一会话时写入;持久化到「自动标题」偏好。
    private func applyAutoTitle(_ title: String, source: TitleSource, sessionId: String) {
        guard self.sessionId == sessionId, source >= titleSource, titleSource < .adapter else { return }
        titleSource = source
        sessionTitle = title
        ClientPrefs.setGeneratedSessionTitle(title, for: sessionId)
        history = history.map { item in
            var copy = item
            if copy.sessionId == sessionId { copy.title = title }
            return copy
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

    private func finishTurn(reason: StopReason?, usage: TurnUsage?, error: Error?) {
        // 先把已合并但尚未应用的事件落入时间线,再结束轮次
        watchdogTask?.cancel()
        watchdogTask = nil
        lastUsedAt = Date()
        let turnMs = turnStart.map { OMLogger.milliseconds(since: $0) } ?? 0
        if let usage, error == nil { promptCache = PromptCacheStats.recording(usage, onto: promptCache) }
        let summaryModel = currentMappedModel?.displayName ?? option(category: "model")?.currentDisplayName ?? ""
        let summaryBrand: ModelBrandHint? = currentMappedModel.map {
            ModelBrandHint(modelId: $0.modelId, providerPreset: $0.presetId, providerName: $0.providerName)
        } ?? (summaryModel.isEmpty ? nil : ModelBrandHint(modelId: summaryModel))
        if let error {
            log.error("轮次失败", error: error, ["turn": "\(turnNumber)", "ms": "\(turnMs)"])
        } else {
            log.info("轮次结束", ["turn": "\(turnNumber)", "reason": reason.map { "\($0)" } ?? "-", "ms": "\(turnMs)", "ttftMs": turnFirstChunkMs.map(String.init) ?? "-", "chunks": "\(turnChunks)", "tools": "\(turnToolCalls)", "changedFiles": "\(turnChangeOrder.count)"])
            PerfStats.shared.record(name: "回合总耗时", micros: turnMs * 1000)
        }
        Task { [weak self] in
            // 响应可能先于尾部通知被处理:先用屏障确认此前的通知都已读入,再等它们全部应用到时间线
            if let self, error == nil, let client = self.client {
                let token = UUID().uuidString
                await client.barrier(token)
                if await self.eventBarrier.wait(token) == false { self.log.warning("等待事件屏障超时", ["turn": "\(self.turnNumber)"]) }
            }
            await self?.coalescer?.drain()
            guard let self else { return }
            self.timeline.finishTurn(aborted: error != nil || reason == .cancelled)
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
                    } else if let hint = AgentErrorHints.message(for: error) {
                        self.timeline.appendNotice(hint, isError: true)
                    } else {
                        self.timeline.appendNotice(String(localized: "请求失败:\(error.localizedDescription)"), isError: true)
                    }
                }
            } else if TurnEndHeuristics.looksTruncated(isClaude: self.activeDescriptor.kind == .claudeACP, reason: reason,
                                                       lastKind: TurnEndHeuristics.lastSubstantiveKind(in: self.timeline.entries)) {
                // 适配器把中断(压缩失败、工具异常等)当作正常结束上报:给出可操作的提示,并指向诊断
                self.log.warning("回合疑似被适配器提前结束", ["turn": "\(self.turnNumber)", "agent": self.activeDescriptor.id,
                                                   "lastStderr": LogRedactor.truncate(self.diagnostics.suffix(2).joined(separator: " | "), limit: 300)])
                let hint = String(localized: "回合可能被提前结束(适配器把中断当作了正常结束)。发送「继续」即可接着往下做;反复出现时请到 设置 → 诊断 查看适配器输出。")
                self.timeline.appendNotice(hint, severity: "warning")
            } else if reason == .refusal {
                self.timeline.appendNotice(ChatL10n.t("模型拒绝了该请求。"))
            } else if reason == .maxTokens {
                self.timeline.appendNotice(ChatL10n.t("已达到输出上限,回复被截断。"))
            } else if reason == .maxTurnRequests {
                self.timeline.appendNotice(ChatL10n.t("已达到单轮请求上限。"))
            }
            self.publishTurnChanges()
            // 回合正常结束:追加结束语(模型、耗时、token、tps);取消或失败不显示
            if error == nil, self.stallMessage == nil, let reason, reason != .cancelled {
                self.timeline.appendTurnSummary(TurnSummary(model: summaryModel, durationSeconds: Double(turnMs) / 1000, usage: usage, brand: summaryBrand, finishedAt: Date()))
            }
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

    /// 会话是否还是「空白」的:没有任何消息、草稿与附件(新建标签时据此复用空白会话标签,避免堆出一排空标签)。
    public var isPristine: Bool { timeline.entries.isEmpty && draft.isEmpty && attachments.isEmpty }

    /// 开始新对话:复用同一 Agent 进程创建新的 ACP 会话,并清空时间线。
    public func newConversation() {
        if isHibernated { whenAwake { [weak self] in self?.newConversation() }; return }
        guard let client, phase == .ready else { return }
        cancel()
        let cwd = workspace.path
        timeline.reset()
        titleTask?.cancel()
        titleSource = .none
        sessionTitle = nil
        goal = nil
        followUps.removeAll()
        usage = nil
        promptCache = nil
        turnChanges.removeAll()
        turnChangeOrder.removeAll()
        Task { await checkpoints.reset() }
        let servers = mcpServers
        let meta = effectiveMeta()
        let dirs = additionalDirectories
        Task { [weak self] in
            do {
                let setup = try await client.newSession(cwd: cwd, mcpServers: servers, additionalDirectories: dirs, meta: meta)
                EmptySessionRegistry.hide(setup.sessionId)
                self?.sessionId = setup.sessionId
                self?.configOptions = setup.configOptions
                self?.applyPreferredMode()
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
            let generated = ClientPrefs.generatedSessionTitles()
            let visible = result.sessions.filter { !EmptySessionRegistry.isHidden($0.sessionId) }
            // 仅当两者都有明确且不等的更新时间时倒序排;若均无更新时间则尊重 Agent 原生返回的原始顺序
            let sorted = visible.sorted { lhs, rhs in
                if let lu = lhs.updatedAt, let ru = rhs.updatedAt, !lu.isEmpty, !ru.isEmpty, lu != ru {
                    return lu > ru
                }
                return false
            }.map { item -> SessionSummary in
                var copy = item
                if let title = overrides[item.sessionId] ?? generated[item.sessionId] { copy.title = title }
                return copy
            }
            self?.history = sorted
        }
    }

    /// 为「尚未连接」的会话登记恢复目标:侧栏从点击瞬间起就以该会话 ID 标识这一行,
    /// 连接后直接 `session/load`,不会先建一个空会话(杜绝顶部闪出「新对话」)。
    /// - Parameter summary: 要恢复的会话摘要
    public func prepareRestore(_ summary: SessionSummary) {
        guard phase == .idle, restoreTarget == nil, sessionId == nil, !summary.sessionId.isEmpty else { return }
        restoreTarget = summary
        // 连接与回放要 1~2 秒:先用本地能拿到的数据把输入框底部与用量环占好位,不等 Agent
        if configOptions.isEmpty, let cached = Self.lastConfigOptions[activeDescriptor.id] { configOptions = cached }
        if let parsing = startTranscriptParse() {
            Task { [weak self] in self?.seedUsage(from: await parsing.value) }
        }
        if let manual = ClientPrefs.sessionTitleOverrides()[summary.sessionId] {
            titleSource = .manual; sessionTitle = manual
        } else if let generated = ClientPrefs.generatedSessionTitles()[summary.sessionId] {
            titleSource = .generated; sessionTitle = generated
        } else {
            titleSource = summary.title?.isEmpty == false ? .adapter : .none
            sessionTitle = summary.title
        }
        sessionId = summary.sessionId
        isReplaying = true
    }

    /// 打开历史会话:优先 `session/load`(回放历史),否则 `session/resume`。
    /// - Parameters:
    ///   - summary: 会话摘要
    ///   - force: 恢复模式下 sessionId 已提前设为目标,需跳过「已是当前会话」的判断
    public func openSession(_ summary: SessionSummary, force: Bool = false) {
        if isHibernated { whenAwake { [weak self] in self?.openSession(summary, force: force) }; return }
        guard let client, phase == .ready, force || summary.sessionId != sessionId, capabilities.loadSession || capabilities.canResume else {
            if force { isReplaying = false; flushQueuedPrompt() }
            return
        }
        cancel()
        timeline.reset()
        goal = nil
        followUps.removeAll()
        turnChanges.removeAll()
        turnChangeOrder.removeAll()
        Task { await checkpoints.reset() }
        titleTask?.cancel()
        if let manual = ClientPrefs.sessionTitleOverrides()[summary.sessionId] {
            titleSource = .manual; sessionTitle = manual
        } else if let generated = ClientPrefs.generatedSessionTitles()[summary.sessionId] {
            titleSource = .generated; sessionTitle = generated
        } else {
            titleSource = summary.title?.isEmpty == false ? .adapter : .none
            sessionTitle = summary.title
        }
        usage = nil
        promptCache = nil
        sessionId = summary.sessionId
        isReplaying = true
        // 会话记录(耗时/完成时间)与回放并行解析:回放一结束就能补上每回合的结束行,不用再等一轮磁盘解析
        let transcriptTurns = startTranscriptParse()
        timeline.beginReplay()
        timeline.replayResolveModel = { [weak self] raw in self?.resolveReplayModel(raw) ?? (raw, nil) }
        if let transcriptTurns {
            // 记录解析完成后立刻交给时间线:此后每个回合一结束就即时补结束行
            Task { [weak self] in
                let turns = await transcriptTurns.value
                self?.timeline.replayTurns = turns
                self?.seedUsage(from: turns)
            }
        }
        let replaySpan = Log.perf.span("历史会话回放", warnMs: 800, ["target": String(summary.sessionId.prefix(8))])
        let cwd = workspace.path
        let canLoad = capabilities.loadSession
        let servers = mcpServers
        let meta = effectiveMeta()
        let dirs = additionalDirectories
        Task { [weak self] in
            do {
                let setup = canLoad
                    ? try await client.loadSession(sessionId: summary.sessionId, cwd: cwd, mcpServers: servers, additionalDirectories: dirs, meta: meta)
                    : try await client.resumeSession(sessionId: summary.sessionId, cwd: cwd, mcpServers: servers, additionalDirectories: dirs, meta: meta)
                self?.configOptions = setup.configOptions.isEmpty ? (self?.configOptions ?? []) : setup.configOptions
            } catch {
                if let rpc = error as? JSONRPCError, rpc.code == -32002 {
                    // Agent 报「会话不存在」:通常是会话属于别的引擎(会话数据由各引擎自己保存),或已被删除
                    self?.timeline.appendNotice(String(localized: "当前引擎找不到这个会话:它可能属于其他引擎,或已被删除。"), isError: true)
                } else {
                    self?.timeline.appendNotice(String(localized: "打开会话失败:\(error.localizedDescription)"), isError: true)
                }
                self?.log.warning("打开历史会话失败", ["target": String(summary.sessionId.prefix(8)), "error": "\(error)"])
            }
            await self?.settleEvents()
            self?.timeline.finishStreaming()
            // 先等记录解析完,再同一步里结束回放并补齐结束行:中间不让出主线程,界面不会先出一版没有结束行的时间线再跳一下
            let parsed = await transcriptTurns?.value
            if let parsed { self?.timeline.replayTurns = parsed }
            self?.timeline.endReplay()
            self?.attachReplayedSummaries(turns: parsed)
            self?.isReplaying = false
            replaySpan.end(["entries": "\(self?.timeline.entries.count ?? 0)"])
            self?.flushQueuedPrompt()
            // 回放后一条内容都没有:多半是 Agent 建会话时落盘、却从没发过消息的空会话。登记后从列表里隐藏
            if let self, self.timeline.entries.isEmpty, self.sessionId == summary.sessionId {
                EmptySessionRegistry.hide(summary.sessionId)
                self.timeline.appendNotice(String(localized: "这个会话里没有任何消息(从未发送过内容),已从列表中隐藏。"))
                self.log.info("历史会话回放为空,已隐藏", ["target": String(summary.sessionId.prefix(8))])
            }
        }
    }

    /// 从已有会话克隆时间线与状态 (用于 Fork Chat)
    public func cloneHistory(from source: SessionModel) {
        self.timeline.reset(with: source.timeline.entries)
        self.turnNumber = source.turnNumber
        self.sessionTitle = source.sessionTitle
        self.titleSource = source.titleSource
    }

    /// 执行服务端分叉 (若后端支持)
    public func forkFrom(source: SessionModel) async {
        guard let srcSessionId = source.sessionId, source.capabilities.canFork else {
            log.warning("源会话不支持分叉,保留本地克隆", ["canFork": "\(source.capabilities.canFork)", "hasSession": "\(source.sessionId != nil)"])
            timeline.appendNotice(String(localized: "当前引擎不支持服务端分叉,已仅复制对话记录。"), severity: "warning")
            return
        }
        // 新标签的会话刚创建,Agent 还在连接:等握手完成后再分叉(最多约 60 秒)
        var waited = 0
        while phase != .ready, !isFailed, waited < 600 {
            try? await Task.sleep(for: .milliseconds(100))
            waited += 1
        }
        guard phase == .ready, let client else {
            log.warning("等待连接就绪失败,保留本地克隆")
            timeline.appendNotice(String(localized: "分叉失败:Agent 未能连接,已仅复制对话记录。"), isError: true)
            return
        }
        let cwd = workspace.path
        let servers = mcpServers
        let meta = effectiveMeta()
        do {
            let setup = try await client.forkSession(sessionId: srcSessionId, cwd: cwd, mcpServers: servers, additionalDirectories: additionalDirectories, meta: meta)
            // 分叉出的会话带有原会话的内容,不属于「空会话」,必须显示在历史里
            EmptySessionRegistry.unhide(setup.sessionId)
            self.sessionId = setup.sessionId
            self.timeline.appendNotice(ChatL10n.t("已分叉为新会话，后续操作不会影响原会话。"))
            if !setup.configOptions.isEmpty { self.configOptions = setup.configOptions }
            self.refreshHistory()
        } catch {
            self.log.warning("服务端分叉失败，保留本地克隆", ["error": "\(error)"])
            self.timeline.appendNotice(String(localized: "分叉失败:\(error.localizedDescription)"), isError: true)
        }
    }

    /// 分叉当前会话,并切换到分叉出的新会话。
    public func forkCurrentSession() {
        if isHibernated { whenAwake { [weak self] in self?.forkCurrentSession() }; return }
        guard let client, let sessionId, capabilities.canFork, !isRunning else { return }
        let cwd = workspace.path
        let servers = mcpServers
        let meta = effectiveMeta()
        let dirs = additionalDirectories
        Task { [weak self] in
            do {
                let setup = try await client.forkSession(sessionId: sessionId, cwd: cwd, mcpServers: servers, additionalDirectories: dirs, meta: meta)
                // 分叉出的会话带有原会话的内容,不属于「空会话」,必须显示在历史里
                EmptySessionRegistry.unhide(setup.sessionId)
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
        if isHibernated { whenAwake { [weak self] in self?.deleteSession(summary) }; return }
        guard let client, capabilities.canDelete, summary.sessionId != sessionId else { return }
        Task { [weak self] in
            try? await client.deleteSession(sessionId: summary.sessionId)
            self?.refreshHistory()
        }
    }

    /// 在引擎侧删除任意会话(含当前正显示的会话,调用方负责随后关闭它)。
    /// - Parameter sessionId: 协议会话 ID
    /// - Returns: 引擎是否确认删除;引擎不支持或失败时为 false(仍应在客户端侧移除)
    public func deleteOnEngine(_ sessionId: String) async -> Bool {
        guard !sessionId.isEmpty else { return false }
        if isHibernated, !(await wakeAndWait()) { return false }
        guard let client, capabilities.canDelete else { return false }
        do {
            try await client.deleteSession(sessionId: sessionId)
            log.info("引擎侧已删除会话", ["target": String(sessionId.prefix(8))])
            return true
        } catch {
            log.warning("引擎侧删除会话失败", ["target": String(sessionId.prefix(8)), "error": "\(error)"])
            return false
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
            await fileIndex.prepare(root: workspace, extraRoots: additionalDirectories.map { URL(fileURLWithPath: $0) })
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
            return CompletionEngine.browserMentionItems(query: context.query) + agents + files + folders
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
        // 纯文字会话禁用了斜杠命令,`/context` 不可用;用量改由记录还原/Agent 上报
        guard supportsContextBreakdown, !isPlainChat, phase == .ready, !isRunning, contextProbeChunks == nil, let client, let sessionId else { return }
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

    /// 主动刷新套餐限额(仅 Claude Code;演示模式不探测,30 秒内复用上次结果)。
    public func refreshPlanUsage() async {
        guard activeDescriptor.kind == .claudeACP, !Toolchain.isDemoMode else { return }
        let cwd = workspace.path
        let tools = await Toolchain.shared.resolve()
        guard let claude = tools.claudePath else { return }
        let environment = tools.environment
        await PlanUsageCenter.shared.refresh(offBy: PlanUsageProbe.offBy(environment: environment)) {
            await PlanUsageProbe.fetch(claude: claude, environment: environment, cwd: cwd)
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
            defer { self.applyPendingModelSelection() }
            guard self.mappedModels != previous else { return }
            let meta = self.effectiveMeta()
            let target = self.mappedModels[.main].map { "\($0.providerName) · \($0.displayName)" } ?? ChatL10n.t("系统默认")
            do {
                if hadConversation, canResume {
                    let setup = try await client.resumeSession(sessionId: sessionId, cwd: cwd, mcpServers: servers, additionalDirectories: additionalDirectories, meta: meta)
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
        let setup = try await client.newSession(cwd: cwd, mcpServers: servers, additionalDirectories: additionalDirectories, meta: meta)
        EmptySessionRegistry.hide(setup.sessionId)
        sessionId = setup.sessionId
        configOptions = setup.configOptions
        contextUsage = nil
        applyPreferredMode()
    }

    // MARK: - 配置选项

    /// 设置配置选项(模式、模型、思考强度等)。
    /// - Parameters:
    ///   - optionId: 选项 ID
    ///   - value: 新值
    ///   - remember: 权限模式是否记为偏好(自动化、沿用偏好本身传 false,避免覆盖用户的选择)
    public func setConfigOption(_ optionId: String, value: String, remember: Bool = true) {
        if isHibernated { whenAwake { [weak self] in self?.setConfigOption(optionId, value: value, remember: remember) }; return }
        guard let client, let sessionId else { return }
        // 切换模型时记录切换前的显示名,成功后在时间线插入分割线
        let isModel = configOptions.first { $0.id == optionId }?.category == "model"
        let previous = isModel ? modelLabel(forValue: configOptions.first { $0.id == optionId }?.currentValue.stringValue) : nil
        // 用户选择的权限模式记下来,新开会话时沿用
        if remember, configOptions.first(where: { $0.id == optionId })?.category == "mode" { PreferredMode.save(value, agentId: activeDescriptor.id) }
        Task { [weak self] in
            do {
                let updated = try await client.setConfigOption(sessionId: sessionId, configId: optionId, value: .string(value))
                if !updated.isEmpty { self?.configOptions = updated }
                if let self, let previous {
                    let next = self.modelLabel(forValue: value)
                    if next != previous { self.timeline.appendModelSwitch(from: previous, to: next) }
                }
            } catch {
                self?.timeline.appendNotice(String(localized: "设置失败:\(error.localizedDescription)"), isError: true)
            }
        }
    }

    /// 在输入框的模型下拉里选择一项,必要时先切换来源(原生 ⇄ 自定义映射)。
    /// 来源变化会写入 providers.json 并刷新会话(上下文保留),刷新完成后再应用所选模型。
    /// - Parameters:
    ///   - optionId: 模型配置项 ID
    ///   - value: 选项值(`default/opus/sonnet/haiku`)
    ///   - useMapping: 目标来源是否为自定义映射
    public func selectModel(optionId: String, value: String, useMapping: Bool) {
        guard !optionId.isEmpty, !value.isEmpty else { return }
        let active = !mappedModels.isEmpty
        guard active != useMapping, activeDescriptor.kind == .claudeACP else {
            setConfigOption(optionId, value: value)
            return
        }
        pendingModelSelection = (optionId, value)
        let directory = providerDirectory
        Task { [weak self] in
            do {
                try await Task.detached(priority: .userInitiated) { try ProviderStorage.setUseMapping(useMapping, directory: directory) }.value
                NotificationCenter.default.post(name: .omModelMappingChanged, object: nil)
            } catch {
                self?.pendingModelSelection = nil
                self?.log.error("切换模型来源失败", error: error)
                self?.timeline.appendNotice(String(localized: "切换模型来源失败:\(error.localizedDescription)"), isError: true)
            }
        }
    }

    /// 来源切换的会话刷新结束后,应用之前选中的模型。
    private func applyPendingModelSelection() {
        guard let pending = pendingModelSelection else { return }
        pendingModelSelection = nil
        setConfigOption(pending.optionId, value: pending.value)
    }

    /// 模型值对应的展示名:启用映射时取「映射名 · 槽位」,否则取选项名,找不到则回退原值。
    /// - Parameter value: 选项值(可为 nil)
    private func modelLabel(forValue value: String?) -> String {
        guard let value else { return "" }
        if let slot = ModelSlot(optionValue: value), let mapped = mappedModels[slot] { return "\(mapped.displayName) · \(slot.title)" }
        return option(category: "model")?.options.first { $0.value == value }?.name ?? value
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
        // 审批策略:终端命令/浏览器访问按「每次询问 / 允许列表 / 自动运行」处理
        if let target = ToolApprovalPolicy.subject(of: call, browserPageURL: BrowserProvider.shared.currentURL(workspace: workspace.path)),
           ToolApprovalPolicy.load(target.domain).decide(subject: target.subject, domain: target.domain) == .allow,
           let option = request.options.first(where: { $0.kind == .allowOnce }) ?? request.options.first(where: { $0.kind == .allowAlways }) {
            log.info("审批策略自动放行", ["domain": target.domain.rawValue, "toolCallId": call.toolCallId])
            return .selected(optionId: option.optionId)
        }
        log.info("请求权限", ["tool": call.title, "kind": "\(call.kind)", "toolCallId": call.toolCallId, "options": request.options.map(\.optionId).joined(separator: ",")])
        return await withCheckedContinuation { continuation in
            let prompt = PermissionPrompt(request: request, continuation: continuation)
            proposePlanIfNeeded(for: prompt)
            pendingPermissions.append(prompt)
        }
    }

    /// 回复权限并从队列移除。
    /// - Parameters:
    ///   - prompt: 请求
    ///   - optionId: 选项
    public func resolve(_ prompt: PermissionPrompt, optionId: String) {
        log.info("权限已回复", ["tool": prompt.title, "option": optionId])
        // 计划卡在请求到达时就已进入时间线(待批准);这里按选择结果回写状态
        if prompt.isPlanApproval, let entry = prompt.planEntry {
            entry.planPending = false
            if let option = prompt.request.options.first(where: { $0.optionId == optionId }),
               option.kind == .allowOnce || option.kind == .allowAlways {
                entry.planBuilt = true
            }
        }
        prompt.choose(optionId)
        pendingPermissions.removeAll { $0.id == prompt.id }
    }

    /// 计划批准请求到达时:把计划作为计划卡立即放进时间线(待批准),让用户先看到计划文档再决定;
    /// 计划文件优先用 Claude Code 自己写的那份(编辑它就是编辑真正的计划),没有才另存一份。
    /// - Parameter prompt: 计划批准请求
    private func proposePlanIfNeeded(for prompt: PermissionPrompt) {
        guard prompt.isPlanApproval, prompt.planEntry == nil, let plan = prompt.planText else { return }
        let entry = timeline.appendPlanDoc(plan)
        entry.planPending = true
        prompt.planEntry = entry
        if let path = prompt.planFilePath, FileManager.default.fileExists(atPath: path) {
            entry.planFileURL = URL(fileURLWithPath: path)
            onPlanProposed?(entry)
        } else {
            persistPlan(entry) { [weak self] in self?.onPlanProposed?(entry) }
        }
    }

    /// 把计划条目写成全局目录下的 `*.plan.md`(后台写入,完成后回填 `planFileURL`)。
    /// - Parameters:
    ///   - entry: 计划条目
    ///   - completion: 写入成功后的回调(主线程)
    public func persistPlan(_ entry: TimelineEntry, completion: (@MainActor () -> Void)? = nil) {
        guard let document = entry.planDocument, entry.planFileURL == nil else { return }
        let directory = planDirectory
        let log = self.log
        Task { [weak entry] in
            do {
                let url = try await Task.detached(priority: .utility) { try PlanStore.save(document, in: directory) }.value
                entry?.planFileURL = url
                completion?()
            } catch {
                log.warning("保存计划文件失败", ["dir": directory.path, "error": error.localizedDescription])
            }
        }
    }

    /// 把计划保存到工作区(`<项目>/.oma/plans/`),便于随项目提交或分享。
    /// - Parameter entry: 计划条目
    /// - Returns: 写入的文件;失败时为 nil(已记录日志)
    @discardableResult
    public func savePlanToWorkspace(_ entry: TimelineEntry) -> URL? {
        guard let document = entry.planDocument else { return nil }
        do {
            let url = try PlanStore.save(document, in: PlanStore.workspaceDirectory(workspace.path))
            entry.planWorkspaceURL = url
            return url
        } catch {
            log.warning("保存计划到工作区失败", ["workspace": workspace.path, "error": error.localizedDescription])
            return nil
        }
    }

    private func cancelPendingPrompts() {
        for prompt in pendingPermissions { prompt.cancel() }
        pendingPermissions.removeAll()
        for prompt in pendingElicitations {
            prompt.cancel()
            if let outcome = prompt.outcome { timeline.attachElicitationOutcome(outcome) }
        }
        pendingElicitations.removeAll()
    }

    // MARK: - 提问(Elicitation)

    func awaitElicitation(method: String, params: JSONValue?) async -> JSONValue {
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
        if let outcome = prompt.outcome, pendingElicitations.contains(where: { $0.id == prompt.id }) {
            timeline.attachElicitationOutcome(outcome)
        }
        pendingElicitations.removeAll { $0.id == prompt.id }
    }

    // MARK: - 终端

    private func registerTerminal(_ created: TerminalCreated) {
        guard let manager = terminalManager else { return }
        let session = TerminalSession(id: created.id, command: created.command)
        session.sandboxed = created.sandboxed
        terminals[created.id] = session
        session.startPolling(manager: manager)
    }

    /// 沙箱拦截后「放行一次」:下一条终端命令不进沙箱,并请 Agent 重试刚才的命令。
    public func retryWithoutSandbox() {
        guard let manager = terminalManager else { return }
        log.info("用户放行一次沙箱")
        Task { [weak self] in
            await manager.allowUnsandboxedOnce()
            self?.send(String(localized: "刚才的命令被沙箱拦截了,已为你放行一次,请不带沙箱重试那条命令。"))
        }
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
        syncExternalTerminal(for: call)
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

    /// 统计回合进度:首个输出分片(TTFT)、分片数、工具调用数。
    private func noteTurnProgress(_ update: SessionUpdate) {
        guard isRunning, let start = turnStart else { return }
        switch update {
        case .agentMessageChunk, .agentThoughtChunk:
            turnChunks += 1
            if turnFirstChunkMs == nil {
                let ms = OMLogger.milliseconds(since: start)
                turnFirstChunkMs = ms
                PerfStats.shared.record(name: "首 token(TTFT)", micros: ms * 1000)
                log.info("首个输出", ["turn": "\(turnNumber)", "ttftMs": "\(ms)"])
            }
        case .toolCall:
            turnToolCalls += 1
        default:
            break
        }
    }

    private func handle(_ events: [ClientEvent]) {
        for event in events {
            switch event {
            case .sessionUpdate(let id, let update):
                guard sessionId == nil || sessionId == id else { continue }
                lastActivity = .now
                noteTurnProgress(update)
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
        observeTerminalMeta(update)
        switch update {
        case .availableCommands(let commands): availableCommands = commands
        case .configOptions(let options): configOptions = options
        case .currentMode(let modeId):
            if let index = configOptions.firstIndex(where: { $0.category == "mode" }) {
                configOptions[index].currentValue = .string(modeId)
            }
        case .sessionInfo(let title, _):
            if let title {
                if let manual = sessionId.flatMap({ ClientPrefs.sessionTitleOverrides()[$0] }) {
                    sessionTitle = manual
                } else {
                    // 适配器推送的标题优先于自动生成/截取的标题
                    titleTask?.cancel()
                    titleSource = .adapter
                    if let sessionId { ClientPrefs.setGeneratedSessionTitle(nil, for: sessionId) }
                    sessionTitle = title
                }
            }
        case .usage(var value):
            // 限额事件、压缩后的用量不带费用:沿用之前的累计费用
            if value.costAmount == nil {
                value.costAmount = usage?.costAmount
                value.costCurrency = usage?.costCurrency
            }
            if let info = value.rateLimit { PlanUsageCenter.shared.apply(rateLimitInfo: info) }
            value.rateLimit = nil
            usage = value
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

    // MARK: - 休眠与唤醒

    /// 当前是否可以休眠:空闲、没有任何进行中的工作,且结束进程后能无损接回。
    /// 运行中、待处理的权限/提问、排队消息、仍在跑的终端或工具(含后台子代理)、回放中一律不休眠。
    public var canHibernate: Bool {
        guard phase == .ready, !isHibernated, !isRunning, !isReplaying, !isShuttingDown else { return false }
        guard activeDescriptor.kind == .claudeACP, connectTask == nil else { return false }
        guard pendingPermissions.isEmpty, pendingElicitations.isEmpty, queuedPrompt == nil, followUps.isEmpty else { return false }
        if terminals.values.contains(where: \.isRunning) { return false }
        if timeline.entries.contains(where: { $0.kind == .tool && ($0.tool?.status == .pending || $0.tool?.status == .inProgress) }) { return false }
        // 有对话内容时必须能用 session/resume 接回;空白会话直接丢弃进程,唤醒时新建
        return timeline.entries.isEmpty || capabilities.canResume
    }

    /// 标记会话刚被使用(切到前台等),让它排在休眠顺序的后面。
    public func touch() {
        lastUsedAt = Date()
    }

    /// 休眠:结束 Agent 进程释放内存,保留时间线、草稿、标题与会话 ID;下次发送或开始输入时自动唤醒。
    /// - Returns: 是否真的进入了休眠(不满足 `canHibernate` 时为 false)
    @discardableResult
    public func hibernate() -> Bool {
        guard canHibernate else { return false }
        let hasConversation = !timeline.entries.isEmpty
        dormantSessionId = hasConversation ? sessionId : nil
        dormantConfig = Dictionary(configOptions.compactMap { option in
            option.category == "model" ? nil : option.currentValue.stringValue.map { (option.id, $0) }
        }, uniquingKeysWith: { first, _ in first })
        log.info("会话休眠", ["entries": "\(timeline.entries.count)", "resume": hasConversation ? "yes" : "no"])
        if let manager = terminalManager { Task { await manager.shutdown() } }
        terminalManager = nil
        shutdownProcess(keepingSession: hasConversation)
        isHibernated = true
        phase = .idle
        return true
    }

    /// 唤醒休眠的会话(幂等;已在连接中则无动作)。
    public func wake() {
        guard isHibernated else { return }
        lastUsedAt = Date()
        log.info("唤醒会话")
        connect()
    }

    /// 唤醒并等待连接结束(就绪或失败)。
    /// - Parameter timeout: 最长等待时间
    /// - Returns: 是否已就绪
    func wakeAndWait(timeout: Duration = .seconds(20)) async -> Bool {
        wake()
        let deadline = ContinuousClock.now + timeout
        while phase != .ready, ContinuousClock.now < deadline {
            if case .failed = phase { return false }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return phase == .ready
    }

    /// 需要 Agent 进程的操作:休眠中先唤醒,就绪后再执行;否则立即执行。
    /// - Parameter action: 要执行的动作
    private func whenAwake(_ action: @escaping @MainActor () -> Void) {
        guard isHibernated else { action(); return }
        wakeActions.append(action)
        wake()
    }

    private func runWakeActions() {
        let actions = wakeActions
        wakeActions = []
        for action in actions { action() }
    }

    /// 用 `session/resume` 接回休眠前的会话;失败(如记录已被清理)则新建会话并在时间线提示,对话文本仍保留。
    /// - Returns: 成功接回的会话 ID;退回新建时为 nil
    /// - Throws: 接回与新建都失败时抛出新建的错误,由连接流程置为失败态(不能带着旧会话 ID 假装就绪)
    private func resumeDormant(_ dormant: String, client: ACPClient, methods: [AuthMethod], servers: [MCPServerConfig]) async throws -> String? {
        let started = ContinuousClock.now
        do {
            let setup = try await client.resumeSession(sessionId: dormant, cwd: workspace.path, mcpServers: servers, additionalDirectories: additionalDirectories, meta: effectiveMeta())
            sessionId = dormant
            if !setup.configOptions.isEmpty { configOptions = setup.configOptions }
            log.info("休眠会话已接回", ["ms": "\(OMLogger.milliseconds(since: started))"])
            return dormant
        } catch {
            log.warning("接回休眠会话失败,改为新建会话", ["error": "\(error)"])
            do {
                let setup = try await newSessionAuthenticating(client: client, methods: methods, servers: servers)
                sessionId = setup.sessionId
                configOptions = setup.configOptions
                applyPreferredMode()
                timeline.appendNotice(String(localized: "无法接回之前的会话上下文,已开始新会话(上方对话记录仍保留)。"), severity: "warning")
            } catch {
                log.error("休眠唤醒后新建会话失败", error: error)
                timeline.appendNotice(String(localized: "唤醒会话失败:\(error.localizedDescription)"), isError: true)
                throw error
            }
            return nil
        }
    }

    /// 把休眠前的权限模式、思考强度等恢复出来(模型由会话记录自带,不处理)。
    private func reapplyDormantConfig() {
        let saved = dormantConfig
        dormantConfig = [:]
        for option in configOptions where option.category != "model" {
            guard let wanted = saved[option.id], option.currentValue.stringValue != wanted else { continue }
            setConfigOption(option.id, value: wanted, remember: false)
        }
    }

    // MARK: - 关闭

    private func shutdownProcess(keepingSession: Bool = false) {
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
        coalescer = nil
        if !keepingSession { sessionId = nil }
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

/// Agent 要求登录但认证失败。
struct AuthenticationFailure: Error, LocalizedError {
    let agent: String
    let reason: String

    var errorDescription: String? {
        String(localized: "「\(agent)」登录失败:\(reason)。请先在终端里完成该 Agent 的登录(例如 Antigravity 运行 `agy`),再点击「重试」。")
    }
}


// MARK: - 会话记录文件

extension SessionModel {
    /// 会话记录文件路径(只认 Claude Code 的存放位置;其他引擎没有这个文件时返回 nil)。
    var transcriptURL: URL? {
        guard let sessionId, !sessionId.isEmpty else { return nil }
        // Claude Code 的目录名:路径里所有非字母数字字符都换成 "-"
        let slug = String(workspace.path.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
        let path = NSHomeDirectory() + "/.claude/projects/\(slug)/\(sessionId).jsonl"
        return FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
    }
}

extension SessionModel {
    /// 无法得知真实窗口时的默认上下文窗口(token)。
    static let defaultContextWindow = 200_000

    /// 重新打开的会话还没有 Agent 上报的用量:用记录里最后一次请求的上下文占用顶上,窗口取默认 20 万(发送后以实际上报为准)。
    /// - Parameter turns: 记录解析出的回合
    func seedUsage(from turns: [TranscriptTurn]) {
        guard usage?.used == nil, let tokens = turns.last(where: { $0.lastContextTokens != nil })?.lastContextTokens else { return }
        usage = UsageUpdate(used: tokens, size: Self.defaultContextWindow)
    }

    /// 在后台开始解析会话记录(没有记录文件的引擎返回 nil)。
    /// - Returns: 解析任务;回放结束后交给 `attachReplayedSummaries(parsing:)`
    func startTranscriptParse() -> Task<[TranscriptTurn], Never>? {
        guard let url = transcriptURL else { return nil }
        return Task.detached(priority: .userInitiated) { TranscriptTurns.parse(url) }
    }

    /// 回放结束后从会话记录补出各回合的耗时与完成时间(没有记录文件的引擎直接跳过)。
    /// - Parameter turns: `startTranscriptParse()` 解析出的回合(nil 表示没有记录文件)
    func attachReplayedSummaries(turns: [TranscriptTurn]?) {
        guard let turns else { return }
        seedUsage(from: turns)
        timeline.attachReplayedSummaries(turns) { [weak self] raw in self?.resolveReplayModel(raw) ?? (raw, nil) }
    }

    /// 把记录里的模型 ID 换成展示名与厂商图标线索。
    /// 经模型映射发出的回合,记录里写的是槽位别名(oma-main 等)或空:用当前映射的真实模型展示。
    /// - Parameter raw: 记录里的模型 ID
    func resolveReplayModel(_ raw: String) -> (name: String, brand: ModelBrandHint?) {
        if raw.isEmpty || raw.hasPrefix("oma-"), let mapped = currentMappedModel {
            return (mapped.displayName, ModelBrandHint(modelId: mapped.modelId, providerPreset: mapped.presetId, providerName: mapped.providerName))
        }
        return (raw, raw.isEmpty ? nil : ModelBrandHint(modelId: raw))
    }
}

