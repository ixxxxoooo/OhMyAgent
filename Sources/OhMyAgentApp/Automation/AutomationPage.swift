// @author ixxxxoooo
// 自动化页:左侧自动化列表,右侧详情(启停、立即运行、运行历史)或编辑表单;空状态提供模板入口。

import AutomationKit
import ChatKit
import DesignSystem
import IconKit
import SwiftUI
import WorkbenchKit

/// 自动化页(编辑区里的一个标签)。
struct AutomationPage: View {
    let workbench: WorkbenchModel
    @State private var selection: UUID?
    @State private var draft: AutomationDraft?
    @State private var showNewPicker = false
    @State private var confirmDelete = false

    private enum Metrics {
        static let listWidth: CGFloat = 240
        static let rowHeight: CGFloat = 44
    }

    private var center: AutomationCenter { AutomationService.shared.center }
    private var selected: Automation? { center.library.automations.first { $0.id == selection } }

    var body: some View {
        HStack(spacing: 0) {
            listColumn
                .frame(width: Metrics.listWidth)
            Divider()
            detailColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(OMColors.surface)
        .onAppear { if selection == nil { selection = center.library.automations.first?.id } }
        .confirmationDialog("删除这个自动化?", isPresented: $confirmDelete) {
            Button("删除", role: .destructive) {
                if let id = selection { center.remove(id); selection = center.library.automations.first?.id }
            }
        } message: {
            Text("同时会删除它的运行记录,已生成的会话不受影响。")
        }
    }

    // MARK: 左列

    private var listColumn: some View {
        VStack(spacing: 0) {
            HStack {
                Text("自动化").font(OMFonts.title)
                Spacer()
                Button { showNewPicker = true } label: {
                    Image.om("plus", size: 14)
                }
                .buttonStyle(.omIcon)
                .omTooltip("新建自动化")
                .accessibilityLabel("新建自动化")
                .omPicker(isPresented: $showNewPicker, entries: newEntries, selectedID: nil, placement: .belowTrailing, width: 280, onSelect: { startNew(with: $0.id) })
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            if center.library.automations.isEmpty {
                emptyList
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(center.library.automations) { automation in row(automation) }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
            }
        }
    }

    /// 新建入口候选:空白 + 模板。
    private var newEntries: [PickEntry] {
        let blank = PickEntry(id: "blank", title: String(localized: "空白自动化"), subtitle: nil, group: nil, icon: "plus")
        let templates = AutomationTemplate.all.map {
            PickEntry(id: "tpl:" + $0.id, title: $0.name, subtitle: $0.summary, group: String(localized: "模板"), icon: "sparkles")
        }
        return [blank] + templates
    }

    private var emptyList: some View {
        VStack(spacing: 8) {
            Spacer()
            Image.om("workflow", size: 22).foregroundStyle(OMColors.tertiaryText)
            Text("还没有自动化").font(OMFonts.small).foregroundStyle(OMColors.secondaryText)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func row(_ automation: Automation) -> some View {
        let isSelected = selection == automation.id && draft == nil
        return Button {
            selection = automation.id
            draft = nil
        } label: {
            HStack(spacing: 8) {
                OMStatusDot(status(of: automation))
                VStack(alignment: .leading, spacing: 2) {
                    Text(automation.name).font(OMFonts.body).lineLimit(1)
                    Text(automation.schedule.summary()).font(OMFonts.caption).foregroundStyle(OMColors.tertiaryText).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: Metrics.rowHeight)
            .background(RoundedRectangle(cornerRadius: OMRadius.control, style: .continuous).fill(isSelected ? OMColors.pressedFill : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(automation.name)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// 列表状态点:运行中 / 最近失败 / 已停用 / 正常。
    private func status(of automation: Automation) -> OMStatusDot.State {
        if center.runningIDs.contains(automation.id) { return .running }
        if !automation.enabled { return .idle }
        switch center.library.runs(for: automation.id).first?.status {
        case .failed, .timedOut: return .failure
        default: return .success
        }
    }

    // MARK: 右列

    @ViewBuilder
    private var detailColumn: some View {
        if draft != nil {
            AutomationEditor(
                draft: Binding(get: { draft ?? AutomationDraft() }, set: { draft = $0 }),
                projects: workbench.orderedProjects,
                onSave: save, onCancel: { draft = nil })
        } else if let automation = selected {
            detail(automation)
        } else {
            welcome
        }
    }

    /// 没有选中项时的引导。
    private var welcome: some View {
        VStack(spacing: 14) {
            Image.om("workflow", size: 30).foregroundStyle(OMColors.tertiaryText)
            Text("让 Agent 按计划自己干活").font(OMFonts.title)
            Text("定时在项目里发送提示词:每日摘要、依赖检查、待办扫描……运行结果与会话都会保留,随时可以接着聊。")
                .font(OMFonts.small).foregroundStyle(OMColors.secondaryText).multilineTextAlignment(.center).frame(maxWidth: 360)
            VStack(spacing: 6) {
                ForEach(AutomationTemplate.all) { template in
                    Button { startNew(with: "tpl:" + template.id) } label: {
                        HStack(spacing: 8) {
                            Image.om("sparkles", size: 13).foregroundStyle(OMColors.accent)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(template.name).font(OMFonts.body)
                                Text(template.summary).font(OMFonts.caption).foregroundStyle(OMColors.tertiaryText)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12).frame(height: 44)
                        .background(OMColors.card, in: RoundedRectangle(cornerRadius: OMMetrics.controlRadius, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: OMMetrics.controlRadius, style: .continuous).strokeBorder(OMColors.hairline, lineWidth: 0.5))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: 360)
            Button("新建空白自动化") { startNew(with: "blank") }.buttonStyle(.omSecondary)
        }
        .padding(24)
    }

    /// 自动化详情:头部操作 + 基本信息 + 提示词 + 运行历史。
    private func detail(_ automation: Automation) -> some View {
        let running = center.runningIDs.contains(automation.id)
        let runs = center.library.runs(for: automation.id)
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    Text(automation.name).font(OMFonts.title).lineLimit(1)
                    Spacer()
                    OMSwitch(String(localized: "启用自动化"), isOn: Binding(
                        get: { automation.enabled }, set: { center.setEnabled($0, for: automation.id) }))
                    if running {
                        Button { center.cancel(automation: automation.id) } label: { Label("停止", om: "square", size: 12) }
                            .buttonStyle(.omSecondary)
                    } else {
                        Button { center.runNow(automation.id) } label: { Label("立即运行", om: "circle-play", size: 13) }
                            .buttonStyle(.omPrimary)
                    }
                    Button { draft = AutomationDraft(automation: automation) } label: { Image.om("pencil", size: 13) }
                        .buttonStyle(.omIcon).omTooltip("编辑").accessibilityLabel("编辑")
                    Button { confirmDelete = true } label: { Image.om("trash", size: 13) }
                        .buttonStyle(.omIcon).omTooltip("删除").accessibilityLabel("删除")
                }
                infoGrid(automation)
                VStack(alignment: .leading, spacing: 6) {
                    Text("提示词").font(OMFonts.sectionTitle)
                    Text(automation.prompt)
                        .font(OMFonts.small).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(OMColors.card, in: RoundedRectangle(cornerRadius: OMMetrics.controlRadius, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: OMMetrics.controlRadius, style: .continuous).strokeBorder(OMColors.hairline, lineWidth: 0.5))
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("运行记录").font(OMFonts.sectionTitle)
                    if runs.isEmpty {
                        Text("还没有运行过。点「立即运行」试一次,或等到下一次计划时间。")
                            .font(OMFonts.small).foregroundStyle(OMColors.tertiaryText)
                    } else {
                        ForEach(runs) { run in runRow(run, automation: automation) }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private func infoGrid(_ automation: Automation) -> some View {
        let projectName = (automation.projectPath as NSString).lastPathComponent
        let next = automation.nextRun().map { $0.formatted(date: .abbreviated, time: .shortened) }
        return VStack(alignment: .leading, spacing: 6) {
            infoRow(String(localized: "项目"), projectName + " · " + (automation.projectPath as NSString).abbreviatingWithTildeInPath)
            infoRow(String(localized: "计划"), automation.schedule.summary())
            infoRow(String(localized: "下次运行"), automation.enabled ? (next ?? "-") : String(localized: "已停用"))
            infoRow(String(localized: "权限"), automation.permissionMode.title)
        }
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title).font(OMFonts.small).foregroundStyle(OMColors.secondaryText).frame(width: 64, alignment: .leading)
            Text(value).font(OMFonts.small).textSelection(.enabled).lineLimit(2)
            Spacer(minLength: 0)
        }
    }

    private func runRow(_ run: AutomationRun, automation: Automation) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                OMStatusDot(runDot(run.status))
                Text(run.status.title).font(OMFonts.small)
                Text(run.startedAt.formatted(date: .abbreviated, time: .shortened)).font(OMFonts.caption).foregroundStyle(OMColors.tertiaryText)
                if let duration = run.duration {
                    Text(Self.durationText(duration)).font(OMFonts.caption).foregroundStyle(OMColors.tertiaryText)
                }
                if run.trigger == .manual { OMTag(String(localized: "手动")) }
                Spacer(minLength: 0)
                if !run.summary.isEmpty { OMCopyButton(help: String(localized: "复制摘要"), size: 12) { run.summary } }
                if let sessionID = run.sessionID {
                    Button { openSession(sessionID, automation: automation) } label: { Label("打开会话", om: "external-link", size: 12) }
                        .buttonStyle(.omPlain)
                }
            }
            if !run.summary.isEmpty {
                Text(run.summary).font(OMFonts.caption).foregroundStyle(OMColors.secondaryText).lineLimit(4).textSelection(.enabled)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(OMColors.card, in: RoundedRectangle(cornerRadius: OMMetrics.controlRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: OMMetrics.controlRadius, style: .continuous).strokeBorder(OMColors.hairline, lineWidth: 0.5))
    }

    private func runDot(_ status: AutomationRunStatus) -> OMStatusDot.State {
        switch status {
        case .running: return .running
        case .succeeded: return .success
        case .failed, .timedOut: return .failure
        case .cancelled: return .idle
        }
    }

    /// 耗时文案:`12 秒` / `3 分 05 秒`。
    static func durationText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return total < 60 ? String(localized: "\(total) 秒") : String(localized: "\(total / 60) 分 \(String(format: "%02d", total % 60)) 秒")
    }

    // MARK: 动作

    /// 按入口 ID 开始新建(`blank` 或 `tpl:<模板 ID>`)。
    private func startNew(with id: String) {
        let project = workbench.selectedProject ?? workbench.orderedProjects.first
        let path = project?.url.path ?? ""
        if id.hasPrefix("tpl:"), let template = AutomationTemplate.all.first(where: { "tpl:" + $0.id == id }) {
            draft = AutomationDraft(template: template, projectPath: path)
        } else {
            var fresh = AutomationDraft()
            fresh.projectPath = path
            draft = fresh
        }
    }

    /// 保存草稿:新建或更新;失败的提示由编辑器显示。
    /// - Returns: 错误提示;成功为 nil
    private func save(_ value: AutomationDraft) -> String? {
        let automation = value.makeAutomation()
        let error = value.id == nil ? center.add(automation) : center.update(automation)
        if error == nil {
            selection = automation.id
            draft = nil
        }
        return error
    }

    /// 在标签中打开某次运行的会话(项目未打开时先打开项目)。
    private func openSession(_ sessionID: String, automation: Automation) {
        let projectID = workbench.projects.first { $0.url.path == automation.projectPath }?.id
            ?? workbench.openProject(URL(fileURLWithPath: automation.projectPath))
        guard let projectID else { return }
        workbench.openHistory(project: projectID, sessionId: sessionID, title: automation.name)
    }
}
