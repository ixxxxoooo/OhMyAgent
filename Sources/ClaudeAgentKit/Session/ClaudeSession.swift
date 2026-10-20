// @author ixxxxoooo
// 会话核心:一个 ACP 会话对应一个 `claude` 子进程。负责启动与初始化握手、状态保存、消息泵与关闭;
// 回合/消息/配置/权限逻辑分散在同名扩展文件中。

import ACPKit
import Foundation
import OMLog

/// 一个 Claude 会话(actor 隔离全部可变状态)。
actor ClaudeSession: ClaudeQueryDelegate {
    // MARK: 标识与依赖

    nonisolated let id: String
    let spec: SessionSpec
    let config: ClaudeAgentConfig
    let client: any AgentClientLink
    let caps: ClientCaps
    let log: OMLogger
    /// 会话结束(进程退出或被关闭)时通知所属 Agent
    let onEnded: @Sendable (String) async -> Void

    // MARK: 进程与消息泵

    var query: ClaudeQuery?
    var consumer: Task<Void, Never>?
    var closed = false
    var resumedFromHistory = false

    // MARK: 创建结果与配置状态

    var claudeSettings = ClaudeSettings()
    var allowBypass = false
    var currentMode = "default"
    var availableModes: [(id: String, name: String, description: String)] = []
    var models = ModelState(available: [], currentModelId: "default")
    var modelInfos: [ModelInfo] = []
    var configOptions: [JSONValue] = []
    var agents: [(name: String, description: String)] = []
    var currentAgent = AgentOptions.defaultId
    var fastEnabled = false
    var fastDisabledReason: String?
    var effortPinned: String?
    var prePlanMode: String?
    var autoFallbackWarnPending = false
    var autoFallbackWarned = false
    var rawCommands: [JSONValue] = []
    /// 已发给客户端的工具调用字段,更新只带变化部分
    var toolFields = ToolCallFieldTracker()
    /// CLI 初始化响应里的账号信息(用于上报鉴权身份)
    var account: JSONValue?
    var terminalCommands: [String] = []
    var userEffort: String?

    // MARK: 翻译与用量

    var translator: MessageTranslator
    var usage = UsageTracker()
    let forwardSubagentText: Bool
    var messageIdToUuid: [String: String] = [:]
    var titleContext = ""
    var titleSettled = false
    var lastPublishedTitle: String?

    // MARK: 钩子

    var hookIds: [String: HookKind] = [:]
    var hookedTools: [String: (name: String, parent: String?)] = [:]

    // MARK: 回合状态

    var turns: [SessionTurn] = []
    var active: SessionTurn?
    var cancelled = false
    var cancelledPrompts: Set<String> = []
    var owedTrailingIdles = 0
    var lastSessionState: String?
    var emittedAssistantText = false
    var liveTasks: [String: LiveTask] = [:]
    var lastAssistantError: String?
    var lastAssistantWasUsageLimit = false
    var lastRefusalExplanation: String?
    var forceSettleTask: Task<Void, Never>?
    var compactionId: String?
    var compactionTerminal: String?
    var compactionDeliveredOutput = false
    var compactionHeartbeat = false

    // MARK: 权限与征询(见 +Permissions)

    var openPermissionRequests = 0
    var pendingClientRequests: [UUID: Task<JSONValue, Error>] = [:]
    var pendingExitPlan: PendingExitPlan?

    init(
        id: String,
        spec: SessionSpec,
        config: ClaudeAgentConfig,
        client: any AgentClientLink,
        caps: ClientCaps,
        forwardSubagentText: Bool,
        onEnded: @escaping @Sendable (String) async -> Void
    ) {
        self.id = id
        self.spec = spec
        self.config = config
        self.client = client
        self.caps = caps
        self.forwardSubagentText = forwardSubagentText
        self.onEnded = onEnded
        self.log = Log.agent.with(["session": id])
        var translator = MessageTranslator(renderer: ToolCallRenderer(capabilities: ToolRenderCapabilities(clientCapabilities: caps.raw)), cwd: spec.cwd)
        translator.supportsPlan = caps.plan
        self.translator = translator
    }

    // MARK: 启动

    /// 启动 `claude`、完成初始化握手并装配模型/模式/配置选项。
    /// - Parameter creation: 创建选项(恢复、分叉、沿用模式等)
    /// - Throws: `JSONRPCError`(会话不存在、cwd 非法等)或通道错误
    func boot(_ creation: SessionCreation) async throws {
        let started = ContinuousClock.now
        claudeSettings = config.settings.load(cwd: spec.cwd)
        let userOptions = spec.meta?.at("claudeCode", "options")
        allowBypass = Self.bypassAllowed && !claudeSettings.bypassDisabled && userOptions?["allowDangerouslySkipPermissions"]?.boolValue != false

        var resumedMode: String?
        var resumedModel: String?
        if let resume = creation.resume {
            let wantsModel: Bool
            if case .some = creation.resumedModelHint { wantsModel = false } else { wantsModel = true }
            let tail = config.store.tail(sessionId: resume, cwd: spec.cwd, withModel: wantsModel)
            resumedMode = tail.permissionMode
            resumedModel = wantsModel ? tail.model : (creation.resumedModelHint ?? nil)
        }
        let initialMode = PermissionModes.initial(explicit: creation.permissionMode, resumed: resumedMode, defaultMode: claudeSettings.defaultMode, allowBypass: allowBypass)
        userEffort = userOptions?["effort"]?.stringValue

        let options = buildOptions(creation: creation, initialMode: initialMode, userOptions: userOptions)
        let transport = config.launcher.makeTransport(for: options)
        let query = ClaudeQuery(transport: transport, delegate: self, label: id)
        self.query = query
        do {
            try await query.start()
        } catch {
            log.error("claude 启动失败", error: error, ["executable": options.executable])
            throw JSONRPCError(code: JSONRPCError.internalError, message: "无法启动 claude:\(error.localizedDescription)")
        }
        startConsumer(query)

        let initResult: JSONValue
        do {
            initResult = try await query.control("initialize", initializeFields(userOptions: userOptions))
        } catch {
            let message = error.localizedDescription
            await query.close()
            self.query = nil
            if creation.resume != nil, message.contains("No conversation found") || message.contains("closed before response") {
                throw JSONRPCError(code: -32002, message: "Resource not found: \(creation.resume ?? id)", data: ["uri": .string(creation.resume ?? id)])
            }
            log.error("初始化握手失败", error: error)
            throw JSONRPCError(code: JSONRPCError.internalError, message: message)
        }
        resumedFromHistory = creation.resume != nil
        try await configure(initResult: initResult, initialMode: initialMode, resumedModel: resumedModel, isResume: creation.resume != nil)
        log.info("会话已就绪", ["resume": creation.resume ?? "-", "model": models.currentModelId, "mode": currentMode, "ms": "\(OMLogger.milliseconds(since: started))"])
    }

    /// Node 适配器的 `ALLOW_BYPASS`:root 下禁用,除非声明沙盒。
    static var bypassAllowed: Bool {
        geteuid() != 0 || ProcessInfo.processInfo.environment["IS_SANDBOX"] != nil
    }

    /// 由会话参数拼出 `claude` 启动选项。
    func buildOptions(creation: SessionCreation, initialMode: String, userOptions: JSONValue?) -> ClaudeCLIOptions {
        var options = ClaudeCLIOptions(executable: config.executable, cwd: spec.cwd)
        options.env = config.environment
        if let extra = userOptions?["env"]?.objectValue {
            for (key, value) in extra { if let text = value.stringValue { options.env[key] = text } }
        }
        options.permissionMode = initialMode
        options.allowDangerouslySkipPermissions = allowBypass
        options.settingSources = ["user", "project", "local"]
        options.includePartialMessages = true
        options.replayUserMessages = true
        options.mcpServers = Self.mcpServerConfigs(spec.mcpServers, extra: userOptions?["mcpServers"])
        options.additionalDirectories = (userOptions?["additionalDirectories"]?.arrayValue ?? []).compactMap(\.stringValue) + spec.additionalDirectories
        options.disallowedTools = (userOptions?["disallowedTools"]?.arrayValue ?? []).compactMap(\.stringValue) + (caps.elicitationForm ? [] : ["AskUserQuestion"])
        options.allowedTools = (userOptions?["allowedTools"]?.arrayValue ?? []).compactMap(\.stringValue)
        if let tools = userOptions?["tools"]?.arrayValue {
            options.tools = .list(tools.compactMap(\.stringValue))
        } else if spec.meta?["disableBuiltInTools"]?.boolValue == true {
            options.tools = .list([])
        } else {
            options.tools = .preset
        }
        if let settings = userOptions?["settings"] { options.settings = settings }
        if let model = userOptions?["model"]?.stringValue { options.model = model }
        if let effort = userOptions?["effort"]?.stringValue { options.effort = effort }
        if let agent = userOptions?["agent"]?.stringValue { options.agent = agent }
        if let maxTurns = userOptions?["maxTurns"]?.intValue { options.maxTurns = maxTurns }
        if let fallback = userOptions?["fallbackModel"]?.stringValue { options.fallbackModel = fallback }
        if let extraArgs = userOptions?["extraArgs"]?.objectValue {
            for (key, value) in extraArgs { options.extraArgs[key] = .some(value.stringValue) }
        }
        if let resume = creation.resume {
            options.resume = resume
            if creation.fork {
                options.forkSession = true
                options.sessionId = id
            }
        } else {
            options.sessionId = creation.reuseSessionId ?? id
        }
        return options
    }

    /// 把 ACP 的 MCP 服务器清单转成 `--mcp-config` 的对象。
    static func mcpServerConfigs(_ servers: [JSONValue], extra: JSONValue?) -> [String: JSONValue] {
        var result = extra?.objectValue ?? [:]
        for server in servers {
            guard let name = server["name"]?.nonEmptyString else { continue }
            func pairs(_ key: String) -> JSONValue? {
                guard let list = server[key]?.arrayValue, !list.isEmpty else { return nil }
                var object: [String: JSONValue] = [:]
                for entry in list { if let key = entry["name"]?.stringValue, let value = entry["value"]?.stringValue { object[key] = .string(value) } }
                return .object(object)
            }
            if let type = server["type"]?.stringValue {
                guard type == "http" || type == "sse" else { continue }
                result[name] = JSONValue.make([("type", .string(type)), ("url", server["url"]), ("headers", pairs("headers"))])
            } else {
                result[name] = JSONValue.make([("type", "stdio"), ("command", server["command"]), ("args", server["args"]), ("env", pairs("env"))])
            }
        }
        return result
    }

    /// `initialize` 控制请求的字段:钩子登记、系统提示词、子代理文本转发、对话框类型。
    func initializeFields(userOptions: JSONValue?) -> [String: JSONValue] {
        var fields: [String: JSONValue] = [:]
        var hooks: [String: JSONValue] = [:]
        var counter = 0
        for kind in [HookKind.postToolUse, .postModelSwitch, .postCompact, .taskCreated, .taskCompleted] {
            let callback = "hook_\(counter)"
            counter += 1
            hookIds[callback] = kind
            hooks[kind.rawValue] = [["hookCallbackIds": [.string(callback)]]]
        }
        fields["hooks"] = .object(hooks)
        if let prompt = spec.meta?["systemPrompt"] {
            if let text = prompt.stringValue {
                fields["systemPrompt"] = [.string(text)]
            } else if let object = prompt.objectValue {
                if let append = object["append"]?.stringValue { fields["appendSystemPrompt"] = .string(append) }
                if let exclude = object["excludeDynamicSections"] { fields["excludeDynamicSections"] = exclude }
            }
        }
        if let agents = userOptions?["agents"] { fields["agents"] = agents }
        if forwardSubagentText { fields["forwardSubagentText"] = true }
        if caps.elicitationForm { fields["supportedDialogKinds"] = [.string(Self.refusalFallbackDialogKind)] }
        return fields
    }

    static let refusalFallbackDialogKind = "refusal_fallback_prompt"

    // MARK: 消息泵

    private func startConsumer(_ query: ClaudeQuery) {
        consumer = Task { [weak self] in
            for await message in query.messages {
                guard let self else { return }
                await self.handle(message)
            }
            await self?.queryEnded()
        }
    }

    /// 进程退出或通道关闭:让排队中的回合以错误收尾并通知 Agent。
    private func queryEnded() async {
        guard !closed else { return }
        let stderr = await query?.recentStderr ?? ""
        closed = true
        let tail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let reason = tail.isEmpty ? "claude 进程已退出" : "claude 进程已退出:\(String(tail.suffix(600)))"
        log.warning("claude 进程结束", ["unsettled": "\(turns.filter { !$0.settled }.count)"])
        let error: Error = tail.contains("Please run /login") || tail.contains("authentication")
            ? JSONRPCError(code: -32000, message: "Authentication required")
            : JSONRPCError(code: JSONRPCError.internalError, message: reason)
        for turn in turns where !turn.settled { turn.reject(error) }
        turns.removeAll()
        active = nil
        await onEnded(id)
    }

    /// 主动关闭会话(取消排队回合、结束进程)。
    func close() async {
        guard !closed else { return }
        closed = true
        forceSettleTask?.cancel()
        let pendingTurns = turns.filter { !$0.settled }
        let outcome = makeOutcome("cancelled")
        for turn in pendingTurns { turn.resolve(outcome) }
        turns.removeAll()
        active = nil
        let query = self.query
        self.query = nil
        consumer?.cancel()
        consumer = nil
        await query?.close()
        log.info("会话已关闭")
    }

    // MARK: 发送辅助

    /// - Parameter replacePinnedContent: PostToolUse 回写的终稿允许覆盖已固定的审批补丁
    func send(_ update: JSONValue, replacePinnedContent: Bool = false) async {
        var update = update
        if let kind = update["sessionUpdate"]?.stringValue, kind == "tool_call" || kind == "tool_call_update" {
            // 终态结果与 PostToolUse 回写可以覆盖已固定的审批补丁
            let final = kind == "tool_call_update" && ["completed", "failed"].contains(update["status"]?.stringValue ?? "")
            guard toolFields.apply(&update, replacePinnedContent: final || replacePinnedContent) else { return }
        }
        await client.sessionUpdate(id, update)
    }

    func send(_ updates: [JSONValue]) async {
        for update in updates { await client.sessionUpdate(id, update) }
    }

    /// 给用量更新附加最近助手回合的模型名。
    func withUsageModel(_ update: JSONValue) -> JSONValue {
        guard let model = usage.lastAssistantModel, var object = update.objectValue else { return update }
        var meta = object["_meta"]?.objectValue ?? [:]
        meta["_claude/model"] = .string(model)
        object["_meta"] = .object(meta)
        return .object(object)
    }

    /// 构造回合收尾结果(含累计用量与配额元数据)。
    func makeOutcome(_ stopReason: String, extraMeta: [String: JSONValue] = [:]) -> PromptOutcome {
        var meta = usage.quotaMeta.objectValue ?? [:]
        for (key, value) in extraMeta { meta[key] = value }
        return PromptOutcome(stopReason: stopReason, usage: usage.promptUsage, meta: .object(meta))
    }
}
