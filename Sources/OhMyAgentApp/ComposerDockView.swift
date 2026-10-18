// @author ixxxxoooo
// 输入栏上方的任务坞(参考 Cursor):排队消息 / 后台子 Agent / 运行中的终端三类,
// 底部是胶囊标签(点击切换面板,再点当前标签收起),上方是对应面板;
// 每行悬停有底色与操作按钮,点击行会以新标签页在主内容区打开详情(子 Agent 的只读会话、终端的只读输出)。

import ACPKit
import ChatKit
import DesignSystem
import IconKit
import SwiftUI
import WorkbenchKit

/// 任务坞。
struct ComposerDockView: View {
    let model: SessionModel
    let workbench: WorkbenchModel

    /// 运行中的子 Agent 条目(含嵌套深度)。
    private var runningSubagents: [(entry: TimelineEntry, depth: Int)] {
        model.timeline.subagentEntries().filter { $0.entry.tool.map { !$0.status.isTerminal } ?? false }
    }

    /// 运行中的终端(按开始时间排序)。
    private var runningTerminals: [TerminalSession] {
        model.terminals.values.filter(\.isRunning).sorted { $0.startedAt < $1.startedAt }
    }

    var body: some View {
        let subagents = runningSubagents
        let terminals = runningTerminals
        let counts: [ComposerDockSection: Int] = [.queued: model.followUps.count, .subagents: subagents.count, .terminals: terminals.count]
        let total = counts.values.reduce(0, +)
        if total > 0 {
            let current = ComposerDockSection.effective(selection: model.dockSelection, hidden: model.dockHidden, counts: counts)
            VStack(alignment: .leading, spacing: 8) {
                if let current {
                    panel(current, counts: counts, subagents: subagents, terminals: terminals)
                        .transition(.opacity)
                }
                chips(current: current, counts: counts)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Color.clear.frame(height: 0)
                .onAppear { model.dockHidden = false }
        }
    }

    // MARK: 胶囊标签

    private func chips(current: ComposerDockSection?, counts: [ComposerDockSection: Int]) -> some View {
        OMGlassGroup(spacing: 6) {
        HStack(spacing: 6) {
            ForEach(ComposerDockSection.allCases, id: \.self) { section in
                let count = counts[section, default: 0]
                if count > 0 {
                    DockChip(icon: Self.icon(section), title: Self.chipTitle(section), count: count, selected: current == section) {
                        omWithAnimation(.snappy(duration: 0.18)) {
                            if current == section {
                                model.dockHidden = true
                            } else {
                                model.dockSelection = section
                                model.dockHidden = false
                            }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        }
    }

    private static func icon(_ section: ComposerDockSection) -> String {
        switch section {
        case .queued: return "hourglass"
        case .subagents: return "bot"
        case .terminals: return "terminal"
        }
    }

    private static func chipTitle(_ section: ComposerDockSection) -> String {
        switch section {
        case .queued: return String(localized: "排队")
        case .subagents: return String(localized: "子 Agent")
        case .terminals: return String(localized: "终端")
        }
    }

    // MARK: 面板

    @ViewBuilder
    private func panel(_ section: ComposerDockSection, counts: [ComposerDockSection: Int],
                       subagents: [(entry: TimelineEntry, depth: Int)], terminals: [TerminalSession]) -> some View {
        let count = counts[section, default: 0]
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(Self.panelTitle(section, count: count))
                    .font(OMFonts.small)
                    .foregroundStyle(OMColors.secondaryText)
                Spacer(minLength: 0)
                if section == .subagents {
                    Button("停止本轮") { model.cancel() }
                        .buttonStyle(.plain)
                        .font(OMFonts.small)
                        .foregroundStyle(OMColors.secondaryText)
                        .omTooltip("停止本轮(含所有子 Agent)")
                }
                Button {
                    omWithAnimation(.snappy(duration: 0.18)) { model.dockHidden = true }
                } label: {
                    Image.om("x", size: 12)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(OMColors.secondaryText)
                .omTooltip("收起")
                .accessibilityLabel("收起任务面板")
            }
            .padding(.horizontal, 12)
            .frame(height: 32)
            ScrollView {
                VStack(spacing: 1) {
                    switch section {
                    case .queued:
                        ForEach(model.followUps) { item in QueuedRow(model: model, item: item) }
                    case .subagents:
                        ActiveTimeline(interval: 1) { _ in
                            VStack(spacing: 1) {
                                ForEach(subagents, id: \.entry.id) { item in
                                    SubagentDockRow(entry: item.entry, depth: item.depth, model: model, workbench: workbench)
                                }
                            }
                        }
                    case .terminals:
                        ActiveTimeline(interval: 1) { _ in
                            VStack(spacing: 1) {
                                ForEach(terminals) { session in
                                    TerminalDockRow(session: session, model: model, workbench: workbench)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(CGFloat(count) * 31 + 6, 196))
        }
        .omGlassCard()
        .accessibilityElement(children: .contain)
    }

    private static func panelTitle(_ section: ComposerDockSection, count: Int) -> String {
        switch section {
        case .queued: return String(localized: "\(count) 条排队,本轮结束后发送")
        case .subagents: return String(localized: "\(count) 个子 Agent 运行中")
        case .terminals: return String(localized: "\(count) 个终端运行中")
        }
    }
}

/// 胶囊标签。
private struct DockChip: View {
    let icon: String
    let title: String
    let count: Int
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image.om(icon, size: 11)
                Text(title)
                Text("\(count)").monospacedDigit().foregroundStyle(OMColors.tertiaryText)
            }
            .font(OMFonts.small)
            .foregroundStyle(selected ? OMColors.primaryText : OMColors.secondaryText)
            .padding(.horizontal, 11)
            .frame(height: 26)
            // 不透明胶囊:选中态叠加选中填充,避免玻璃采样/着色让文字发虚
            .background(OMPillShape().fill(OMColors.opaqueChrome))
            .background(OMPillShape().fill(selected ? OMColors.selectedFill : Color.clear))
            .overlay(OMPillShape().stroke(OMColors.hairline, lineWidth: 0.5))
            .contentShape(OMPillShape())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// 面板行的外壳:悬停底色;非悬停显示 `meta`,悬停显示 `actions`。
private struct DockRowShell<Leading: View, Actions: View>: View {
    let title: String
    let meta: String?
    let tap: (() -> Void)?
    @ViewBuilder let leading: Leading
    @ViewBuilder let actions: Actions
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            leading.frame(width: 16)
            Text(title)
                .font(OMFonts.small)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if hovering {
                actions
            } else if let meta {
                Text(meta)
                    .font(OMFonts.caption)
                    .monospacedDigit()
                    .foregroundStyle(OMColors.tertiaryText)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(hovering ? OMColors.hoverFill : Color.clear, in: RoundedRectangle(cornerRadius: OMRadius.control, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { tap?() }
        .omTooltip(title)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(tap == nil ? [] : .isButton)
    }
}

/// 行内小图标按钮。
private struct RowIconButton: View {
    let icon: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image.om(icon, size: 12)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(OMColors.secondaryText)
        .omTooltip(label)
        .accessibilityLabel(label)
    }
}

/// 排队消息行:悬停出现「引导/发送」「编辑」「删除」。
private struct QueuedRow: View {
    let model: SessionModel
    let item: QueuedMessage

    var body: some View {
        DockRowShell(title: item.text.replacingOccurrences(of: "\n", with: " "), meta: nil, tap: nil) {
            Image.om(item.images.isEmpty ? "message-square" : "image", size: 12).foregroundStyle(OMColors.tertiaryText)
        } actions: {
            HStack(spacing: 2) {
                Button(model.isRunning ? String(localized: "引导") : String(localized: "发送")) { model.sendFollowUpNow(item.id) }
                    .buttonStyle(.plain)
                    .font(OMFonts.small)
                    .foregroundStyle(OMColors.secondaryText)
                    .disabled(model.isRunning && !model.canSteer)
                    .omTooltip(model.isRunning ? String(localized: "立即引导进当前轮次") : String(localized: "立即发送"))
                    .padding(.trailing, 4)
                RowIconButton(icon: "pencil", label: String(localized: "编辑")) { model.editFollowUp(item.id) }
                RowIconButton(icon: "trash", label: String(localized: "移除")) { model.removeFollowUp(item.id) }
            }
        }
    }
}

/// 运行中的子 Agent 行:点击以新标签页打开其只读会话。
private struct SubagentDockRow: View {
    let entry: TimelineEntry
    let depth: Int
    let model: SessionModel
    let workbench: WorkbenchModel

    var body: some View {
        if let tool = entry.tool {
            let presentation = ToolPresentation(tool: tool, hasChild: true)
            DockRowShell(title: presentation.subject, meta: meta(presentation), tap: { open(tool) }) {
                Image.om(SubagentIcon.symbol(for: presentation.agentType), size: 12).foregroundStyle(OMColors.accent)
            } actions: {
                HStack(spacing: 4) {
                    Text("在新标签页打开").font(OMFonts.caption).foregroundStyle(OMColors.tertiaryText)
                    RowIconButton(icon: "external-link", label: String(localized: "在新标签页打开")) { open(tool) }
                }
            }
            .padding(.leading, CGFloat(depth * 12))
        }
    }

    /// 灰色元信息:类型 · 最近工具 · 已运行时长。
    private func meta(_ presentation: ToolPresentation) -> String {
        var parts: [String] = []
        if let type = presentation.agentType { parts.append(type) }
        if let last = entry.childStore?.entries.last(where: { $0.kind == .tool })?.tool?.title, !last.isEmpty { parts.append(last) }
        parts.append(WorkingStatus.elapsed(Int(entry.elapsedSeconds)))
        return parts.joined(separator: " · ")
    }

    private func open(_ tool: ToolCall) {
        guard let project = workbench.projectID(of: model) else { return }
        workbench.openSubagent(project: project, toolCallID: tool.toolCallId, title: tool.title)
    }
}

/// 运行中的终端行:点击以新标签页只读查看输出,悬停出现「终止」。
private struct TerminalDockRow: View {
    let session: TerminalSession
    let model: SessionModel
    let workbench: WorkbenchModel

    var body: some View {
        DockRowShell(title: session.command, meta: WorkingStatus.elapsed(Int(Date().timeIntervalSince(session.startedAt))), tap: viewInPanel) {
            Image.om("terminal", size: 12).foregroundStyle(OMColors.secondaryText)
        } actions: {
            HStack(spacing: 2) {
                RowIconButton(icon: "external-link", label: String(localized: "在新标签页打开")) { open() }
                if !session.isExternal {
                    RowIconButton(icon: "square", label: String(localized: "终止")) { model.interruptTerminal(session.id) }
                }
            }
        }
    }

    /// 点击行:在终端面板里查看(终端在编辑区时退回只读标签页)。
    private func viewInPanel() { AppActions.shared.viewAgentTerminal(session, model: model) }

    private func open() {
        guard let project = workbench.projectID(of: model) else { return }
        workbench.openAgentTerminal(project: project, terminalID: session.id, title: session.command)
    }
}
