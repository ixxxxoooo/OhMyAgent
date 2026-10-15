// @author ygw
// 会话模型:一个窗口对应一个 SessionModel,独占一个 Agent 子进程与一个 ACP 会话。
// 后台:事件接收与合并;主 actor:只应用合并后的批次。

import ACPKit
import AgentHost
import Foundation
import Observation

/// 待处理的权限请求。
@MainActor
@Observable
public final class PermissionPrompt: Identifiable {
    public nonisolated let id = UUID()
    public let request: PermissionRequest
    /// 工具标题(来自请求中的 toolCall)
    public let title: String
    public let kind: ToolKind
    public var isResolved = false
    private var continuation: CheckedContinuation<PermissionOutcome, Never>?

    init(request: PermissionRequest, continuation: CheckedContinuation<PermissionOutcome, Never>) {
        self.request = request
        self.title = request.toolCallRaw["title"]?.stringValue ?? "工具调用"
        self.kind = ToolKind(rawOrOther: request.toolCallRaw["kind"]?.stringValue)
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

/// 反向请求委托:权限请求转交给主 actor 的会话模型。
struct SessionDelegate: ACPClientDelegate {
    let ask: @Sendable (PermissionRequest) async -> PermissionOutcome

    func requestPermission(_ request: PermissionRequest) async -> PermissionOutcome {
        await ask(request)
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
    public let timeline = TimelineStore()

    public private(set) var phase: SessionPhase = .idle
    public private(set) var isRunning = false
    public private(set) var agentName: String
    public private(set) var configOptions: [SessionConfigOption] = []
    public private(set) var availableCommands: [AvailableCommand] = []
    public private(set) var usage: UsageUpdate?
    public private(set) var sessionTitle: String?
    public private(set) var authStatus: String?
    public private(set) var pendingPermissions: [PermissionPrompt] = []
    public private(set) var sessionId: String?
    /// 最近的 stderr 行(诊断用,最多 200 行)
    public private(set) var diagnostics: [String] = []
    /// 连接完成后自动发送的排队消息
    public private(set) var queuedPrompt: String?
    /// 输入框草稿
    public var draft = ""

    private var supervisor: AgentSupervisor?
    private var client: ACPClient?
    private var coalescer: EventCoalescer?
    private var pumpTasks: [Task<Void, Never>] = []
    private var promptTask: Task<Void, Never>?
    private var connectTask: Task<Void, Never>?
    private var isShuttingDown = false

    /// 创建会话模型。
    /// - Parameters:
    ///   - workspace: 工作区目录
    ///   - descriptor: Agent 描述符
    public init(workspace: URL, descriptor: AgentDescriptor = Toolchain.defaultDescriptor()) {
        self.workspace = workspace
        self.descriptor = descriptor
        self.agentName = descriptor.name
    }

    // MARK: - 连接

    /// 后台预热连接(幂等)。窗口首帧后调用。
    public func connect() {
        guard connectTask == nil, phase == .idle || isFailed else { return }
        phase = .connecting
        let descriptor = descriptor
        let cwd = workspace.path
        connectTask = Task { [weak self] in
            let tools = await Toolchain.shared.resolve()
            guard let self else { return }
            let delegate = SessionDelegate { [weak self] request in
                guard let self else { return .cancelled }
                return await self.awaitPermission(request)
            }
            let supervisor = AgentSupervisor(provider: AgentProviders.make(descriptor), cwd: cwd, delegate: delegate)
            do {
                let result = try await supervisor.start(tools: tools)
                guard let client = await supervisor.client else { throw AgentLaunchError.missingAdapter }
                self.attach(supervisor: supervisor, client: client, result: result)
                let setup = try await client.newSession(cwd: cwd)
                self.sessionId = setup.sessionId
                self.configOptions = setup.configOptions
                self.phase = .ready
                self.connectTask = nil
                self.flushQueuedPrompt()
            } catch {
                await supervisor.stop()
                self.phase = .failed(error.localizedDescription)
                self.connectTask = nil
            }
        }
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
        let coalescer = EventCoalescer()
        self.coalescer = coalescer
        // 后台:读取事件并合并
        let reader = Task.detached(priority: .userInitiated) {
            for await event in client.events { coalescer.push(event) }
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

    private func start(prompt: String) {
        guard let client, let sessionId else { return }
        timeline.appendUser(prompt)
        isRunning = true
        promptTask = Task { [weak self] in
            do {
                let reason = try await client.prompt(sessionId: sessionId, content: [.text(prompt)])
                self?.finishTurn(reason: reason, error: nil)
            } catch {
                self?.finishTurn(reason: nil, error: error)
            }
        }
    }

    private func finishTurn(reason: StopReason?, error: Error?) {
        // 先把已合并但尚未应用的事件落入时间线,再结束轮次
        coalescer?.flush()
        Task { [weak self] in
            // 让出一次,使 flush 产生的批次先被应用
            await Task.yield()
            guard let self else { return }
            self.timeline.finishStreaming()
            if let error {
                if !self.isShuttingDown { self.timeline.appendNotice("请求失败:\(error.localizedDescription)", isError: true) }
            } else if reason == .refusal {
                self.timeline.appendNotice("模型拒绝了该请求。")
            } else if reason == .maxTokens {
                self.timeline.appendNotice("已达到输出上限,回复被截断。")
            } else if reason == .maxTurnRequests {
                self.timeline.appendNotice("已达到单轮请求上限。")
            }
            self.isRunning = false
            self.promptTask = nil
        }
    }

    /// 取消当前轮次,并拒绝所有待处理权限。
    public func cancel() {
        guard isRunning, let client, let sessionId else { return }
        for prompt in pendingPermissions { prompt.cancel() }
        pendingPermissions.removeAll()
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
        Task { [weak self] in
            do {
                let setup = try await client.newSession(cwd: cwd)
                self?.sessionId = setup.sessionId
                self?.configOptions = setup.configOptions
            } catch {
                self?.timeline.appendNotice("创建新对话失败:\(error.localizedDescription)", isError: true)
            }
        }
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
        await withCheckedContinuation { continuation in
            let prompt = PermissionPrompt(request: request, continuation: continuation)
            pendingPermissions.append(prompt)
        }
    }

    /// 回复权限并从队列移除。
    /// - Parameters:
    ///   - prompt: 请求
    ///   - optionId: 选项
    public func resolve(_ prompt: PermissionPrompt, optionId: String) {
        prompt.choose(optionId)
        pendingPermissions.removeAll { $0.id == prompt.id }
    }

    // MARK: - 事件处理

    private func handle(_ events: [ClientEvent]) {
        for event in events {
            switch event {
            case .sessionUpdate(let id, let update):
                guard sessionId == nil || sessionId == id else { continue }
                handle(update)
            case .authStatus(let kind, let label, let detail):
                authStatus = [label, detail].compactMap { $0 }.first ?? kind
            case .stderr(let text):
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
        for prompt in pendingPermissions { prompt.cancel() }
        pendingPermissions.removeAll()
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
        let supervisor = supervisor
        self.supervisor = nil
        client = nil
        sessionId = nil
        if let supervisor { Task { await supervisor.stop() } }
    }

    /// 关闭窗口时调用:终止 Agent 子进程。
    public func shutdown() {
        isShuttingDown = true
        for prompt in pendingPermissions { prompt.cancel() }
        pendingPermissions.removeAll()
        shutdownProcess()
    }
}
