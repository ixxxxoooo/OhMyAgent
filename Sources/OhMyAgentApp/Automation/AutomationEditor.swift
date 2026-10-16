// @author ixxxxoooo
// 自动化编辑表单:名称、项目、计划(间隔 / 每天 / 每周 / cron)、权限、提示词。

import AutomationKit
import DesignSystem
import IconKit
import SwiftUI
import WorkbenchKit

/// 自动化编辑表单。
struct AutomationEditor: View {
    @Binding var draft: AutomationDraft
    let projects: [ProjectEntry]
    /// 保存回调:返回错误提示,成功为 nil
    let onSave: (AutomationDraft) -> String?
    let onCancel: () -> Void
    @State private var errorMessage: String?
    @State private var showProjectPicker = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(draft.id == nil ? "新建自动化" : "编辑自动化").font(OMFonts.title)
                field("名称") {
                    TextField("", text: $draft.name, prompt: Text("例如:每日变更摘要"))
                        .textFieldStyle(.roundedBorder).labelsHidden()
                }
                field("项目") { projectButton }
                field("计划") { scheduleEditor }
                field("权限") {
                    OMCompactSegmented(
                        options: AutomationPermissionMode.allCases.map { ($0, $0.title) },
                        selection: $draft.permissionMode, accessibilityName: String(localized: "权限"))
                    Text("无人值守时,需要额外授权的操作(如运行命令)会被自动拒绝。")
                        .font(OMFonts.caption).foregroundStyle(OMColors.tertiaryText)
                }
                field("提示词") {
                    TextEditor(text: $draft.prompt)
                        .font(OMFonts.body)
                        .frame(minHeight: 140)
                        .settingsEditorStyle()
                        .accessibilityLabel("提示词")
                }
                if let errorMessage {
                    Text(errorMessage).font(OMFonts.small).foregroundStyle(OMColors.danger)
                }
                HStack(spacing: 8) {
                    Button("保存") { errorMessage = onSave(draft) }.buttonStyle(.omPrimary)
                    Button("取消", action: onCancel).buttonStyle(.omSecondary)
                }
            }
            .padding(20)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onChange(of: draft) { errorMessage = nil }
    }

    /// 带标题的表单行。
    private func field<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(OMFonts.sectionTitle)
            content()
        }
    }

    // MARK: 项目

    private var projectButton: some View {
        let current = projects.first { $0.url.path == draft.projectPath }
        return Button { showProjectPicker = true } label: {
            HStack(spacing: 6) {
                Text(current?.name ?? (draft.projectPath.isEmpty ? String(localized: "选择项目") : (draft.projectPath as NSString).lastPathComponent))
                    .font(OMFonts.small).lineLimit(1)
                Image.om("chevrons-up-down", size: 11).foregroundStyle(OMColors.tertiaryText)
            }
        }
        .buttonStyle(.omSecondary)
        .accessibilityLabel("选择项目")
        .omPicker(
            isPresented: $showProjectPicker,
            entries: projects.map { PickEntry(id: $0.url.path, title: $0.name, subtitle: ($0.url.path as NSString).abbreviatingWithTildeInPath, group: nil, icon: "folder") },
            selectedID: draft.projectPath, placement: .below, width: 320,
            onSelect: { draft.projectPath = $0.id })
    }

    // MARK: 计划

    @ViewBuilder
    private var scheduleEditor: some View {
        OMCompactSegmented(
            options: AutomationScheduleKind.allCases.map { ($0, $0.title) },
            selection: $draft.kind, accessibilityName: String(localized: "计划类型"))
        switch draft.kind {
        case .interval:
            HStack(spacing: 6) {
                Text("每隔").font(OMFonts.small)
                TextField("", value: $draft.intervalMinutes, format: .number)
                    .textFieldStyle(.roundedBorder).labelsHidden().frame(width: 72).multilineTextAlignment(.trailing)
                Text("分钟(最少 5)").font(OMFonts.small)
            }
        case .daily:
            timeRow
        case .weekly:
            weekdayRow
            timeRow
        case .cron:
            TextField("", text: $draft.cronExpression, prompt: Text("分 时 日 月 周,如 0 9 * * 1-5"))
                .textFieldStyle(.roundedBorder).labelsHidden().font(OMFonts.mono)
        }
        if let next = draft.schedule.nextRun(after: Date()), draft.schedule.validationMessage() == nil {
            Text("下一次:\(next.formatted(date: .abbreviated, time: .shortened))")
                .font(OMFonts.caption).foregroundStyle(OMColors.tertiaryText)
        }
    }

    private var timeRow: some View {
        HStack(spacing: 6) {
            Text("时间").font(OMFonts.small)
            DatePicker("", selection: timeBinding, displayedComponents: .hourAndMinute).labelsHidden()
        }
    }

    /// 时刻与草稿里的时、分互转。
    private var timeBinding: Binding<Date> {
        Binding(
            get: { Calendar.current.date(bySettingHour: draft.hour, minute: draft.minute, second: 0, of: Date()) ?? Date() },
            set: {
                draft.hour = Calendar.current.component(.hour, from: $0)
                draft.minute = Calendar.current.component(.minute, from: $0)
            })
    }

    /// 星期多选(周一在前)。
    private var weekdayRow: some View {
        let symbols = Calendar.current.shortStandaloneWeekdaySymbols
        return HStack(spacing: 4) {
            ForEach([2, 3, 4, 5, 6, 7, 1], id: \.self) { day in
                let on = draft.weekdays.contains(day)
                Button {
                    if on { draft.weekdays.remove(day) } else { draft.weekdays.insert(day) }
                } label: {
                    Text(symbols[day - 1]).font(OMFonts.caption)
                        .foregroundStyle(on ? OMColors.onAccent : Color.primary)
                        .frame(width: 38, height: 24)
                        .background(Capsule().fill(on ? OMColors.accent : Color.primary.opacity(0.06)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(symbols[day - 1])
                .accessibilityAddTraits(on ? [.isSelected] : [])
            }
        }
    }
}
