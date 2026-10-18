// @author ixxxxoooo
// 计划模式的界面(对标 Cursor Plan):待批准的计划卡(标题、概述、TODO 列表、Build 按钮)、
// 时间线里的计划卡(已 Build 标记、TODO 进度、保存到工作区、在新会话中 Build、复制)。

import ACPKit
import ChatKit
import DesignSystem
import IconKit
import SwiftUI
import WorkbenchKit

// MARK: - 动作

/// 计划相关的应用层动作。
@MainActor
enum PlanActions {
    /// 「Build」发给 Agent 的提示。
    /// - Parameters:
    ///   - document: 计划
    ///   - fileURL: 计划文件(有则一并告诉 Agent,便于它回看)
    static func buildPrompt(_ document: PlanDocument, fileURL: URL?) -> String {
        var text = String(localized: "请按下面的计划开始实施")
        if let fileURL { text += String(localized: "(计划文件:\(fileURL.path))") }
        return text + ":\n\n" + document.body
    }

    /// 在新会话里 Build:同一项目新开会话,把计划作为首条消息发送。
    /// - Parameters:
    ///   - document: 计划
    ///   - fileURL: 计划文件
    ///   - model: 当前会话(用来定位项目)
    /// - Returns: 是否成功发起
    @discardableResult
    static func buildInNewSession(_ document: PlanDocument, fileURL: URL?, from model: SessionModel) -> Bool {
        let workbench = AppEnvironment.shared.workbench
        guard let project = workbench.projectID(of: model) else { return false }
        workbench.newConversation(in: project)
        guard let session = workbench.activeSession else { return false }
        session.send(buildPrompt(document, fileURL: fileURL))
        return true
    }

    /// 在指定项目里新开会话并 Build(计划标签页使用,没有所属会话)。
    /// - Parameters:
    ///   - document: 计划
    ///   - fileURL: 计划文件
    ///   - projectID: 项目;nil 取当前选中的项目
    /// - Returns: 是否成功发起
    @discardableResult
    static func buildInNewSession(_ document: PlanDocument, fileURL: URL?, projectID: String?) -> Bool {
        let workbench = AppEnvironment.shared.workbench
        guard let project = projectID ?? workbench.selectedProjectID else { return false }
        workbench.newConversation(in: project)
        guard let session = workbench.activeSession else { return false }
        session.send(buildPrompt(document, fileURL: fileURL))
        return true
    }

    /// 路径缩写(主目录显示为 `~`)。
    /// - Parameter url: 文件地址
    static func displayPath(_ url: URL) -> String {
        let home = NSHomeDirectory()
        return url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
    }
}

// MARK: - TODO 列表

/// 计划里的 TODO 列表(状态图标 + 文字)。
struct PlanTodoList: View {
    let todos: [PlanTodo]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(todos) { todo in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    icon(todo.status)
                        .frame(width: 14)
                    Text(todo.content)
                        .font(OMFonts.body)
                        .strikethrough(todo.status == "completed")
                        .foregroundStyle(todo.status == "completed" ? OMColors.secondaryText : OMColors.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private func icon(_ status: String) -> some View {
        switch status {
        case "completed": Image.om("circle-check", size: 13).foregroundStyle(OMColors.success)
        case "in_progress": Image.om("circle-dashed", size: 13).foregroundStyle(OMColors.accent)
        default: Image.om("circle", size: 13).foregroundStyle(OMColors.tertiaryText)
        }
    }
}

// MARK: - 待批准的计划卡

/// 计划待批准:标题、概述、TODO 列表、可展开的完整计划,以及 Build / 继续规划。
struct PlanApprovalCard: View {
    let prompt: PermissionPrompt
    let onChoose: (String) -> Void
    @Environment(SessionModel.self) private var model
    @State private var showFull = false

    private var document: PlanDocument { PlanDocument.parse(markdown: prompt.planText ?? "") }

    var body: some View {
        let plan = document
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image.om("list-todo").foregroundStyle(OMColors.warning)
                Text("计划待批准").font(OMFonts.small.weight(.medium))
                Spacer()
                OMCopyButton(help: String(localized: "复制计划"), size: 12) { plan.body }
                Button {
                    // 当前会话保持规划状态(选「继续规划」),计划交给新会话实施
                    if PlanActions.buildInNewSession(plan, fileURL: nil, from: model),
                       let reject = prompt.request.options.first(where: { $0.kind == .rejectOnce || $0.kind == .rejectAlways }) {
                        onChoose(reject.optionId)
                    }
                } label: {
                    Image.om("git-fork", size: 12)
                }
                .buttonStyle(.omIcon)
                .omTooltip("在新会话中 Build(当前会话保持规划)")
                .accessibilityLabel("在新会话中 Build")
            }
            Text(plan.name).font(OMFonts.body.weight(.medium)).textSelection(.enabled)
            if !plan.overview.isEmpty {
                Text(plan.overview).font(OMFonts.small).foregroundStyle(OMColors.secondaryText).textSelection(.enabled)
            }
            if !plan.todos.isEmpty { PlanTodoList(todos: plan.todos) }
            Button {
                omWithAnimation { showFull.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image.om(showFull ? "chevron.down" : "chevron.right", size: 10)
                    Text(showFull ? "收起完整计划" : "查看完整计划").font(OMFonts.small)
                }
                .foregroundStyle(OMColors.secondaryText)
            }
            .buttonStyle(.plain)
            if showFull {
                AutoHeightScroll(maxHeight: 320) {
                    MarkdownView(text: plan.body).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            HStack(spacing: 8) {
                ForEach(prompt.request.options) { option in
                    Button(label(for: option)) { onChoose(option.optionId) }
                        .buttonStyle(style(for: option))
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .omGlassCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("计划待批准:\(plan.name)")
    }

    /// 选项文案:批准类统一以 Build 开头,更贴近「开始实施」的语义。
    private func label(for option: PermissionOption) -> String {
        switch option.kind {
        case .allowAlways: return String(localized: "Build · 自动接受编辑")
        case .allowOnce: return String(localized: "Build · 逐项确认")
        default: return option.name
        }
    }

    /// 样式:「自动接受编辑」是唯一的实心主操作(暖色),其余为次按钮。
    private func style(for option: PermissionOption) -> OMButtonStyle {
        option.kind == .allowAlways ? OMButtonStyle(.warm) : OMButtonStyle(.secondary)
    }
}

// MARK: - 时间线里的计划卡

/// 批准后留在时间线里的计划卡。
struct PlanDocView: View {
    let entry: TimelineEntry
    @Environment(SessionModel.self) private var model
    @State private var expanded = false
    @State private var savedNote: String?

    private var document: PlanDocument { entry.planDocument ?? PlanDocument.parse(markdown: entry.text) }

    /// 待办状态:已 Build 的计划按 Agent 最新的待办进度刷新。
    private var todos: [PlanTodo] {
        let plan = document
        guard entry.planBuilt,
              let latest = model.timeline.entries.last(where: { $0.kind == .plan }), !latest.plan.isEmpty else { return plan.todos }
        return plan.syncedTodos(with: latest.plan.map { ($0.content, $0.status) })
    }

    var body: some View {
        let plan = document
        let items = todos
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("计划", om: "list-todo")
                    .font(OMFonts.small.weight(.medium))
                    .foregroundStyle(OMColors.secondaryText)
                if entry.planBuilt { OMTag(String(localized: "已 Build"), tint: OMColors.success) }
                if !items.isEmpty {
                    Text("\(items.filter { $0.status == "completed" }.count)/\(items.count)")
                        .font(OMFonts.caption)
                        .foregroundStyle(OMColors.tertiaryText)
                }
                Spacer()
            }
            Text(plan.name).font(OMFonts.body.weight(.medium)).textSelection(.enabled)
            if !plan.overview.isEmpty {
                Text(plan.overview).font(OMFonts.small).foregroundStyle(OMColors.secondaryText).textSelection(.enabled)
            }
            if !items.isEmpty { PlanTodoList(todos: items) }
            if expanded {
                Divider().overlay(OMColors.hairline)
                MarkdownView(text: plan.body)
            }
            footer(plan)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .omSolidCard()
    }

    private func footer(_ plan: PlanDocument) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button(expanded ? "收起计划" : "查看完整计划") { omWithAnimation { expanded.toggle() } }
                    .buttonStyle(.omPlain)
                Button("在新会话中 Build") { PlanActions.buildInNewSession(plan, fileURL: entry.planFileURL, from: model) }
                    .buttonStyle(.omPlain)
                if let file = entry.planFileURL {
                    Button("在标签页打开") { AppEnvironment.shared.workbench.openPlan(path: file.path, title: plan.name) }
                        .buttonStyle(.omPlain)
                }
                Button(entry.planWorkspaceURL == nil ? "保存到工作区" : "已保存到工作区") {
                    if let url = model.savePlanToWorkspace(entry) {
                        savedNote = String(localized: "已保存到 \(url.path.replacingOccurrences(of: model.workspace.path + "/", with: ""))")
                    }
                }
                .buttonStyle(.omPlain)
                .disabled(entry.planWorkspaceURL != nil)
                Spacer()
                OMCopyButton(help: String(localized: "复制计划"), size: 12) { plan.body }
            }
            if let note = savedNote ?? entry.planWorkspaceURL.map({ String(localized: "已保存到 \($0.path.replacingOccurrences(of: model.workspace.path + "/", with: ""))") }) {
                Text(note).font(OMFonts.caption).foregroundStyle(OMColors.success)
            }
            if let file = entry.planFileURL {
                Text(PlanActions.displayPath(file))
                    .font(OMFonts.caption)
                    .foregroundStyle(OMColors.tertiaryText)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }
}
