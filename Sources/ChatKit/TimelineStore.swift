// @author ixxxxoooo
// 时间线模型:把 ACP 的 session/update 流归并为可渲染的条目。
// 每个条目是独立的 @Observable 对象,流式追加文本时只会让对应条目的视图刷新。

import ACPKit
import DiffKit
import Foundation
import Observation

/// 时间线条目。
@MainActor
@Observable
public final class TimelineEntry: Identifiable {
    /// 条目类别。
    public enum Kind: Sendable {
        case user, assistant, thought, tool, plan, notice, changes
        /// 计划模式批准后的 Markdown 计划文档
        case planDoc
        /// 回合结束语:模型、耗时、token、tps
        case turnSummary
        /// 模型切换分割线:`text` 为切换前模型名,`detail` 为切换后模型名
        case modelSwitch
    }

    public nonisolated let id = UUID()
    public let kind: Kind
    /// 文本内容(用户、助手、思维、提示)
    public var text: String
    /// 工具调用(`kind == .tool`)
    public var tool: ToolCall?
    /// 计划条目(`kind == .plan`)
    public var plan: [PlanEntry] = []
    /// 是否仍在流式接收
    public var isStreaming: Bool
    /// 提示是否为错误(`kind == .notice`)
    public var isError = false
    /// 提示的补充说明(`kind == .notice`,支持 Markdown)
    public var detail: String?
    /// 提示严重程度:info / warning / error(`kind == .notice`)
    public var severity = "info"
    /// 淡色小字样式(`kind == .notice`):用于第三方 Agent 的指标类通知(如 TPS 行),不抢正文注意力
    public var isMuted = false
    /// 用户消息附带的图片(`kind == .user`)
    public var attachments: [ImageAttachment] = []
    /// 该用户消息是运行中引导进当前轮次的(`kind == .user`)
    public var isSteered = false

    /// 用于显示的正文:用户消息带图片附件时,去掉 Claude Code 写在原文里的 `[Image #N]` 占位符
    /// (图片已作为缩略图显示,占位符只是噪音)。消息原文 `text` 不变,编辑重发仍用原文。
    public var displayText: String {
        guard kind == .user, !attachments.isEmpty, text.contains("[Image #") else { return text }
        let stripped = text.replacingOccurrences(of: #"\[Image #\d+\]\s*"#, with: "", options: .regularExpression)
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    public let startedAt = Date()
    public var finishedAt: Date?
    /// 协议消息 ID,用于把分片归并到同一条消息
    public var messageId: String?
    /// 子 Agent 内部的时间线(`kind == .tool` 且该工具派生了子 Agent 时存在)
    public var childStore: TimelineStore?
    /// 本轮文件改动汇总(`kind == .changes`)
    public var changes: [FileChange] = []
    /// 改动所属轮次
    public var turn = 0
    /// 回合结束语(`kind == .turnSummary`)
    public var summary: TurnSummary?
    /// 回放时从本地会话记录得知的整轮耗时(`kind == .user`):回合结束行要等回放结束才插入,
    /// 在此之前凭它就能把已结束的回合折成「已工作 …」,避免回放结束时整段过程突然折叠、画面跳动。
    public var replayDuration: Double?
    /// 提问结果(`kind == .tool` 且为 AskUserQuestion:回答/跳过后写入,用于渲染问答卡)
    public var elicitationOutcome: ElicitationOutcome?
    /// 计划文档(`kind == .planDoc`):解析出的标题、概述、待办与正文
    public var planDocument: PlanDocument?
    /// 计划已落盘的文件(`~/.claude/plans/*.plan.md`);写入完成前为 nil
    public var planFileURL: URL?
    /// 计划是否已点「Build」(只有批准时才追踪,在别处实现不会回写)
    public var planBuilt = false
    /// 计划正等待批准(Agent 提交了计划、用户还没选择):时间线里的计划卡显示「待批准」并默认展开
    public var planPending = false
    /// 计划已保存到工作区的文件(`<项目>/.oma/plans/*.plan.md`)
    public var planWorkspaceURL: URL?

    /// 创建条目。
    /// - Parameters:
    ///   - kind: 类别
    ///   - text: 初始文本
    ///   - isStreaming: 是否流式中
    public init(kind: Kind, text: String = "", isStreaming: Bool = false) {
        self.kind = kind
        self.text = text
        self.isStreaming = isStreaming
    }

    /// 思考耗时(秒)。
    public var elapsedSeconds: Double {
        (finishedAt ?? Date()).timeIntervalSince(startedAt)
    }
}

/// 随消息发送的图片附件。
public struct ImageAttachment: Identifiable, Sendable, Hashable {
    public let id: UUID
    /// 图片原始数据(PNG/JPEG 等)
    public var data: Data
    public var mimeType: String
    /// 显示名(如文件名或「粘贴的图片」)
    public var name: String

    public init(id: UUID = UUID(), data: Data, mimeType: String, name: String) {
        self.id = id
        self.data = data
        self.mimeType = mimeType
        self.name = name
    }

    /// 单张图片大小上限(Claude 接口限制单图 5 MB)
    public static let maxBytes = 5 * 1024 * 1024

    /// 转为 ACP 内容块。
    public var contentBlock: ContentBlock {
        .image(data: data.base64EncodedString(), mimeType: mimeType, uri: nil)
    }
}

/// 单个文件的改动记录(用于“本轮改动”汇总与回退)。
@MainActor
@Observable
public final class FileChange: Identifiable {
    /// 回退状态。
    public enum Status: Sendable, Equatable {
        case pending
        case reverted
        case partiallyReverted
        case conflict
        case failed(String)
    }

    public nonisolated let id = UUID()
    public let path: String
    /// 改动前内容(nil 表示新建)
    public private(set) var original: String?
    /// Agent 写入后的内容
    public private(set) var current: String
    public var status: Status = .pending
    /// 当前差异(原始内容 → 当前内容)
    public private(set) var diff: FileDiff

    /// 创建改动记录。
    public init(path: String, original: String?, current: String) {
        self.path = path
        self.original = original
        self.current = current
        self.diff = LineDiff.diff(old: original, new: current)
    }

    /// 更新为回退后的内容并重新计算差异。
    /// - Parameter text: 回退后的文件内容
    public func updateCurrent(_ text: String) {
        current = text
        diff = LineDiff.diff(old: original, new: text)
    }

    /// 文件名。
    public var fileName: String { (path as NSString).lastPathComponent }
}

/// 时间线存储。仅在主 actor 使用;更新来自合并后的批次,频率不高于约 80 次/秒。
@MainActor
@Observable
public final class TimelineStore {
    public private(set) var entries: [TimelineEntry] = []
    /// 每次变更自增,视图据此决定是否滚动到底部。
    public private(set) var revision = 0
    /// 结构变更计数:条目增删、工具/计划等会影响分组的更新才自增;纯文本分片追加不计入,
    /// 流式输出时据此跳过对整条时间线的重新分组(大会话每个批次 O(n) 的开销)。
    public private(set) var structureRevision = 0

    private var toolIndex: [String: TimelineEntry] = [:]
    private var planEntry: TimelineEntry?
    /// 工具调用状态变化回调(含子 Agent 内部的调用),用于记录检查点等。
    public var onToolChange: ((ToolCall) -> Void)?

    // MARK: 回放时即时补结束行

    /// 历史回放中:会话记录解析出的回合(就绪后,每个回合一结束就立刻插入结束行,不等回放全部结束)
    public var replayTurns: [TranscriptTurn]?
    /// 把记录里的模型 ID 换成展示名与厂商图标线索
    public var replayResolveModel: (String) -> (name: String, brand: ModelBrandHint?) = { ($0, $0.isEmpty ? nil : ModelBrandHint(modelId: $0)) }
    private var replayActive = false
    private var replayPrompts = 0
    private var replayTurnStart: Int?
    private var replayEarly: [TimelineEntry] = []

    public init() {}

    /// 开始回放:重置即时补结束行的状态。
    public func beginReplay() {
        replayActive = true
        replayPrompts = 0
        replayTurnStart = nil
        replayEarly = []
        replayTurns = nil
    }

    /// 结束回放:补上最后一个回合的结束行;回合数与记录对不上时撤回即时插入的结束行,交给「从末尾对齐」的补齐逻辑。
    public func endReplay() {
        guard replayActive else { return }
        finishStreaming()
        insertEarlySummary()
        if let turns = replayTurns, turns.count != replayPrompts {
            let early = Set(replayEarly.map(\.id))
            entries.removeAll { early.contains($0.id) }
            revision += 1
            structureRevision += 1
        }
        replayActive = false
        replayEarly = []
        replayTurnStart = nil
    }

    /// 给刚结束的回合插入结束行(记录已就绪且回合序号对得上时)。
    private func insertEarlySummary() {
        guard replayActive, let start = replayTurnStart, let turns = replayTurns, replayPrompts - 1 < turns.count,
              entries.count > start + 1, let last = entries.last, last.kind != .turnSummary else { return }
        let turn = turns[replayPrompts - 1]
        let texts = entries[(start + 1)...].filter { $0.kind == .assistant }.map(\.text).filter { !$0.isEmpty }
        let resolved = replayResolveModel(turn.model)
        let summary = TurnSummary(model: resolved.name, durationSeconds: turn.end.timeIntervalSince(turn.start), usage: turn.usage, brand: resolved.brand,
                                  outputText: texts.joined(separator: "\n\n"), finishedAt: turn.end)
        let entry = TimelineEntry(kind: .turnSummary, text: summary.copyText)
        entry.summary = summary
        entries.append(entry)
        replayEarly.append(entry)
    }

    /// 按工具调用 ID 查找条目。
    /// - Parameter id: 工具调用 ID
    public func entry(forTool id: String) -> TimelineEntry? { toolIndex[id] }

    /// 清空时间线。
    public func reset() {
        entries.removeAll()
        toolIndex.removeAll()
        planEntry = nil
        revision += 1
        structureRevision += 1
    }

    /// 用给定的条目列表重设时间线 (用于 Fork 会话)
    public func reset(with entries: [TimelineEntry]) {
        self.entries = entries
        self.toolIndex.removeAll()
        for entry in entries where entry.kind == .tool {
            if let tool = entry.tool { toolIndex[tool.id] = entry }
        }
        self.planEntry = entries.last { $0.kind == .plan }
        self.revision += 1
        self.structureRevision += 1
    }

    /// 追加用户消息(本地发送)。
    /// - Parameters:
    ///   - text: 用户输入
    ///   - attachments: 随消息发送的图片
    ///   - steered: 是否为运行中引导进当前轮次的消息
    public func appendUser(_ text: String, attachments: [ImageAttachment] = [], steered: Bool = false) {
        finishStreaming()
        if !steered { planEntry = nil }
        let entry = TimelineEntry(kind: .user, text: text)
        entry.attachments = attachments
        entry.isSteered = steered
        entries.append(entry)
        revision += 1
        structureRevision += 1
    }

    /// 追加计划文档(计划模式批准后)。
    /// - Parameter markdown: 计划 Markdown
    /// - Returns: 新增的计划条目(已解析出 `planDocument`,`planBuilt` 为 false,由调用方按批准结果设置)
    @discardableResult
    public func appendPlanDoc(_ markdown: String) -> TimelineEntry {
        finishStreaming()
        let entry = TimelineEntry(kind: .planDoc, text: markdown)
        entry.planDocument = PlanDocument.parse(markdown: markdown)
        entries.append(entry)
        revision += 1
        structureRevision += 1
        return entry
    }

    /// 追加提示或错误。
    /// - Parameters:
    ///   - text: 文本
    ///   - isError: 是否错误
    ///   - detail: 补充说明(Markdown)
    ///   - severity: 严重程度(info/warning/error);为空时由 `isError` 推导
    public func appendNotice(_ text: String, isError: Bool = false, detail: String? = nil, severity: String? = nil) {
        finishStreaming()
        let entry = TimelineEntry(kind: .notice, text: text)
        entry.isError = isError || severity == "error"
        entry.severity = severity ?? (isError ? "error" : "info")
        entry.detail = detail
        entries.append(entry)
        revision += 1
        structureRevision += 1
    }

    /// 追加模型切换分割线(时间线中显示「由 X 切换为 Y」)。
    /// - Parameters:
    ///   - from: 切换前的模型名
    ///   - to: 切换后的模型名
    public func appendModelSwitch(from: String, to: String) {
        finishStreaming()
        let entry = TimelineEntry(kind: .modelSwitch, text: from)
        entry.detail = to
        entries.append(entry)
        revision += 1
        structureRevision += 1
    }

    /// 结束当前流式条目(轮次结束或切换类型时调用)。
    public func finishStreaming() {
        guard let last = entries.last, last.isStreaming else { return }
        last.isStreaming = false
        last.finishedAt = Date()
    }

    /// 轮次结束时收尾:结束流式,并把未终结的工具调用收口(部分 Agent 不补发最终状态)。
    /// - Parameter aborted: 轮次被取消或出错时为 true,未终结的工具标记为失败;正常结束标记为完成
    public func finishTurn(aborted: Bool = false) {
        finishStreaming()
        for entry in entries where entry.kind == .tool {
            guard let tool = entry.tool, !tool.status.isTerminal else { continue }
            var updated = tool
            updated.status = aborted ? .failed : .completed
            entry.tool = updated
            if entry.finishedAt == nil { entry.finishedAt = Date() }
            onToolChange?(updated)
        }
    }

    /// 应用一个会话更新;与时间线无关的更新会被忽略。
    /// - Parameter update: 协议更新
    public func apply(_ update: SessionUpdate) {
        let countBefore = entries.count
        switch update {
        case .userMessageChunk(let messageId, let content):
            appendChunk(kind: .user, messageId: messageId, content: content)
        case .agentMessageChunk(let messageId, let content):
            appendChunk(kind: .assistant, messageId: messageId, content: content)
        case .agentThoughtChunk(let messageId, let content):
            appendChunk(kind: .thought, messageId: messageId, content: content)
        case .toolCall(let call):
            finishStreaming()
            if let existing = toolIndex[call.toolCallId] {
                existing.tool = call
                if call.status.isTerminal, existing.finishedAt == nil { existing.finishedAt = Date() }
                onToolChange?(call)
            } else {
                let entry = TimelineEntry(kind: .tool, isStreaming: false)
                entry.tool = call
                if call.status.isTerminal, entry.finishedAt == nil { entry.finishedAt = Date() }
                toolIndex[call.toolCallId] = entry
                entries.append(entry)
                onToolChange?(call)
            }
        case .toolCallUpdate(let toolCallId, let raw):
            if let existing = toolIndex[toolCallId], var call = existing.tool {
                call.apply(update: raw)
                existing.tool = call
                if call.status.isTerminal, existing.finishedAt == nil { existing.finishedAt = Date() }
                onToolChange?(call)
            } else {
                finishStreaming()
                let entry = TimelineEntry(kind: .tool)
                let call = ToolCall(json: raw)
                entry.tool = call
                if call.status.isTerminal, entry.finishedAt == nil { entry.finishedAt = Date() }
                toolIndex[toolCallId] = entry
                entries.append(entry)
                onToolChange?(call)
            }
        case .plan(let items):
            if let planEntry {
                planEntry.plan = items
            } else {
                finishStreaming()
                let entry = TimelineEntry(kind: .plan)
                entry.plan = items
                planEntry = entry
                entries.append(entry)
            }
        case .notice(let severity, let title, let detail):
            // 网关场景下 Claude Code 的「auto 模式分类器计费」警告与用户操作无关,直接丢弃
            if NoticeFilter.isClassifierBillingNotice(title: title, detail: detail) { return }
            appendNotice(title, detail: detail?.isEmpty == false ? detail : nil, severity: severity)
        case .agentNotify(let level, let text):
            // info 级别可在设置里隐藏;warning / error 一律显示
            if level == "info", !ClientPrefs.showsAgentNotify() { return }
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { return }
            appendNotice(clean, severity: level == "warning" || level == "error" ? level : "info")
            entries.last?.isMuted = level == "info"
        case .planMarkdown(let markdown):
            finishStreaming()
            entries.append(TimelineEntry(kind: .planDoc, text: markdown))
        case .childUpdate(let parent, let inner):
            // 多层子 Agent:父工具可能位于更深一层的子存储里
            if let parentEntry = toolIndex[parent] ?? toolEntry(id: parent) {
                let child = parentEntry.childStore ?? makeChildStore(for: parentEntry)
                child.apply(inner)
            } else {
                apply(inner)
            }
        default:
            return
        }
        revision += 1
        switch update {
        case .userMessageChunk, .agentMessageChunk, .agentThoughtChunk:
            // 文本分片并入已有条目不改变分组结构
            if entries.count != countBefore { structureRevision += 1 }
        default:
            structureRevision += 1
        }
    }

    /// 把提问结果挂到最近一条尚无结果的 AskUserQuestion 工具条目上;找不到(适配器没有回传工具调用)时补一条已完成的合成工具条目。
    /// - Parameter outcome: 提问结果快照
    public func attachElicitationOutcome(_ outcome: ElicitationOutcome) {
        let target = entries.last { entry in
            guard entry.kind == .tool, entry.elicitationOutcome == nil, let tool = entry.tool else { return false }
            return ElicitationOutcome.isAskQuestion(tool)
        }
        if let target {
            target.elicitationOutcome = outcome
            if target.finishedAt == nil { target.finishedAt = Date() }
        } else {
            finishStreaming()
            let entry = TimelineEntry(kind: .tool)
            entry.tool = ToolCall(toolCallId: "elicit-\(UUID().uuidString)", name: "AskUserQuestion", title: "Asking for your input", kind: .other, status: .completed)
            entry.elicitationOutcome = outcome
            entry.finishedAt = Date()
            entries.append(entry)
        }
        revision += 1
        structureRevision += 1
    }

    /// 在本存储及其全部子存储中按工具调用 ID 查找条目(支持多层子 Agent)。
    /// - Parameter id: 工具调用 ID
    /// - Returns: 对应的工具条目;不存在时为 nil
    public func toolEntry(id: String) -> TimelineEntry? {
        for entry in entries where entry.kind == .tool {
            if entry.tool?.toolCallId == id { return entry }
            if let found = entry.childStore?.toolEntry(id: id) { return found }
        }
        return nil
    }

    /// 全部子 Agent 条目(深度优先,附带嵌套深度),用于侧栏缩进展示、任务坞与子 Agent 标签。
    ///
    /// 判定:已有内部时间线的工具,**或**本身就是子 Agent 启动工具(Task/Agent)的工具。
    /// 只看内部时间线会漏掉「刚启动、还没产出任何内容」与「不回传内部过程」的子 Agent,
    /// 表现为任务坞偶尔不显示正在运行的子 Agent。
    public func subagentEntries(depth: Int = 0) -> [(entry: TimelineEntry, depth: Int)] {
        var result: [(TimelineEntry, Int)] = []
        for entry in entries where entry.kind == .tool {
            if let child = entry.childStore {
                result.append((entry, depth))
                result.append(contentsOf: child.subagentEntries(depth: depth + 1))
            } else if let tool = entry.tool, ToolPresentation.isSubagentLaunch(tool) {
                result.append((entry, depth))
            }
        }
        return result
    }

    private func makeChildStore(for entry: TimelineEntry) -> TimelineStore {
        let child = TimelineStore()
        child.onToolChange = { [weak self] call in self?.onToolChange?(call) }
        entry.childStore = child
        return child
    }

    /// 最近一轮的助手输出正文:从末尾向前收集 `.assistant` 条目,遇到用户消息或上一轮结束语即停止。
    /// - Returns: 多条助手消息以空行连接的 Markdown 原文;没有输出时为空串。
    public func latestTurnOutput() -> String {
        var pieces: [String] = []
        for entry in entries.reversed() {
            if entry.kind == .user || entry.kind == .turnSummary { break }
            if entry.kind == .assistant, !entry.text.isEmpty { pieces.append(entry.text) }
        }
        return pieces.reversed().joined(separator: "\n\n")
    }

    /// 追加回合结束语条目。
    /// - Parameter summary: 本轮摘要
    public func appendTurnSummary(_ summary: TurnSummary) {
        finishStreaming()
        var summary = summary
        if summary.outputText.isEmpty { summary.outputText = latestTurnOutput() }
        let entry = TimelineEntry(kind: .turnSummary, text: summary.copyText)
        entry.summary = summary
        entries.append(entry)
        revision += 1
        structureRevision += 1
    }

    /// 给回放出来的历史回合补上结束行(耗时 + 完成时间)。回放不会产生结束行,这里按会话记录里的时间戳补齐。
    /// 对齐方式:把时间线里的用户消息与记录里的提问从末尾往前一一对应(两边数量可能不同,取较少者)。
    /// - Parameters:
    ///   - turns: 记录解析出的回合
    ///   - resolveModel: 把记录里的模型 ID 换成展示名与厂商图标线索(默认原样显示并按模型名匹配图标)
    public func attachReplayedSummaries(
        _ turns: [TranscriptTurn],
        resolveModel: (String) -> (name: String, brand: ModelBrandHint?) = { ($0, $0.isEmpty ? nil : ModelBrandHint(modelId: $0)) }
    ) {
        let users = entries.indices.filter { entries[$0].kind == .user && !entries[$0].isSteered }
        let count = min(users.count, turns.count)
        guard count > 0 else { return }
        var inserted = false
        // 从后往前插入,前面的下标不受影响
        for offset in stride(from: count - 1, through: 0, by: -1) {
            let userPosition = users.count - count + offset
            let turn = turns[turns.count - count + offset]
            let end = userPosition + 1 < users.count ? users[userPosition + 1] : entries.count
            guard end > users[userPosition] + 1, entries[end - 1].kind != .turnSummary else { continue }
            let texts = entries[(users[userPosition] + 1)..<end].filter { $0.kind == .assistant }.map(\.text).filter { !$0.isEmpty }
            let resolved = resolveModel(turn.model)
            let summary = TurnSummary(model: resolved.name, durationSeconds: turn.end.timeIntervalSince(turn.start), usage: turn.usage, brand: resolved.brand,
                                      outputText: texts.joined(separator: "\n\n"), finishedAt: turn.end)
            let entry = TimelineEntry(kind: .turnSummary, text: summary.copyText)
            entry.summary = summary
            entries.insert(entry, at: end)
            inserted = true
        }
        if inserted { revision += 1; structureRevision += 1 }
    }

    /// 追加“本轮改动”汇总条目。
    /// - Parameters:
    ///   - turn: 轮次
    ///   - changes: 文件改动
    public func appendChanges(turn: Int, changes: [FileChange]) {
        guard !changes.isEmpty else { return }
        finishStreaming()
        let entry = TimelineEntry(kind: .changes)
        entry.turn = turn
        entry.changes = changes
        entries.append(entry)
        revision += 1
        structureRevision += 1
    }

    /// 文本分片归并:同类、仍在流式、消息 ID 兼容时追加,否则新建条目。
    private func appendChunk(kind: TimelineEntry.Kind, messageId: String?, content: ContentBlock) {
        let text: String
        // 用户消息里的图片(历史重放)还原为图片附件,而不是退化成「[图片]」文字
        var attachment: ImageAttachment?
        switch content {
        case .text(let value): text = value
        case .resourceLink(_, let name, _, let title): text = "[\(title ?? name)]"
        case .image(let base64, let mimeType, _):
            if kind == .user, let data = Data(base64Encoded: base64), !data.isEmpty {
                attachment = ImageAttachment(data: data, mimeType: mimeType, name: String(localized: "图片"))
                text = ""
            } else {
                text = String(localized: "[图片]")
            }
        case .audio: text = String(localized: "[音频]")
        default: return
        }
        if let last = entries.last, last.kind == kind, last.isStreaming,
           messageId == nil || last.messageId == nil || last.messageId == messageId {
            last.text += text
            if let attachment { last.attachments.append(attachment) }
            if last.messageId == nil { last.messageId = messageId }
            return
        }
        finishStreaming()
        if replayActive, kind == .user {
            // 新回合开始:上一回合已结束,立刻补它的结束行
            if replayPrompts > 0 { insertEarlySummary() }
            replayPrompts += 1
            replayTurnStart = entries.count
        }
        let entry = TimelineEntry(kind: kind, text: text, isStreaming: true)
        if replayActive, kind == .user, let turns = replayTurns, replayPrompts - 1 < turns.count {
            let turn = turns[replayPrompts - 1]
            entry.replayDuration = max(turn.end.timeIntervalSince(turn.start), 0)
        }
        entry.messageId = messageId
        if let attachment { entry.attachments = [attachment] }
        entries.append(entry)
    }
}
