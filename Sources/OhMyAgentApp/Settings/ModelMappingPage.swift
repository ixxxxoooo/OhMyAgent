// @author ixxxxoooo
// 设置页:Claude Code 模型映射。为 Claude Code 的各个模型槽位(默认/Opus/Sonnet/Haiku/子 Agent)
// 从「任意提供商的任意模型」里下拉选择。只有默认槽位设置后映射才生效;未单独设置的槽位沿用默认槽位。
// 映射对新建会话与重新连接生效,空闲中的会话会即时刷新;不改动 ~/.claude/settings.json。

import ChatKit
import DesignSystem
import IconKit
import SwiftUI

/// Claude Code 模型映射页。
struct ModelMappingPage: View {
    @State private var model = ProviderSettingsModel()
    @AppStorage(ClientPrefs.Key.titleModel) private var titleChoice = ""
    @AppStorage(ClientPrefs.Key.optimizeModel) private var optimizeChoice = ""

    var body: some View {
        Form {
            Section {
                Note("给 Claude Code 里的每个模型槽位指定真实使用的模型。输入框里的模型选择器会显示这里选定的模型;未设置默认槽位时,沿用 ~/.claude 里的配置(也就是你在终端里使用的 claude)。")
                if model.snapshot.providers.isEmpty {
                    Label("还没有模型提供商", om: "info").foregroundStyle(OMColors.secondaryText)
                    Button("去添加提供商") { SettingsRouter.shared.go(.providers) }
                }
            }
            if model.snapshot.mapping[.main] != nil {
                Section {
                    Toggle(isOn: Binding(get: { model.snapshot.useMapping }, set: { model.setUseMapping($0) })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("使用自定义映射")
                            Text("关闭后保留下方映射,Claude Code 使用 ~/.claude 与官方登录(与终端一致);也可在输入框的模型下拉里直接切换。")
                                .font(OMFonts.caption).foregroundStyle(OMColors.secondaryText)
                        }
                    }
                    .toggleStyle(.switch).controlSize(.small)
                }
            }
            Section("槽位") {
                ForEach(ModelSlot.allCases) { slot in slotRow(slot) }
            }
            Section("辅助任务模型") {
                utilityRow(.title)
                utilityRow(.optimize)
                Note("会话标题生成、提示词优化这类轻量请求可单独指定模型,与会话本身使用的模型互不影响,也不要求启用上面的映射。建议选便宜、快的非推理模型;「自动」使用 Haiku 槽位(未映射时,提示词优化改用本机 claude)。对之后的请求立即生效。")
            }
            Section {
                statusRow
                if !model.snapshot.mapping.isEmpty {
                    Button("清除全部映射(回到 ~/.claude 默认)", role: .destructive) {
                        for slot in ModelSlot.allCases { model.setMapping(slot, nil) }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .settingsSurface()
        .onAppear { model.reload() }
    }

    // MARK: - 槽位行

    private func slotRow(_ slot: ModelSlot) -> some View {
        LabeledContent {
            picker(slot)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: slot.title)
                Text(verbatim: slot.detail).font(OMFonts.caption).foregroundStyle(OMColors.tertiaryText)
            }
        }
        // 没有默认槽位时,其他槽位无法生效
        .disabled(slot != .main && model.snapshot.mapping[.main] == nil)
    }

    /// 一个槽位的选择器:点击弹出带搜索的列表(跟随默认 + 按提供商分组的全部可用模型,每行厂商图标 + 复制按钮)。
    private func picker(_ slot: ModelSlot) -> some View {
        let current = model.snapshot.mapping[slot]
        return SlotPickerButton(
            sections: pickerSections(slot: slot, current: current),
            label: { pickerLabel(slot: slot, current: current) },
            onPick: { id in
                if id == Self.followID {
                    model.setMapping(slot, nil)
                } else if let target = Self.decode(id) {
                    model.setMapping(slot, target)
                }
            }
        )
        .accessibilityLabel(String(localized: "\(slot.title) 使用的模型"))
    }

    private static let followID = "__follow__"
    private static let autoID = "__auto__"

    /// 行 ID 编码:`提供商ID\u{1F}模型ID`(避开模型名里常见的分隔符)。
    private static func encode(_ target: ModelTarget) -> String { "\(target.providerId)\u{1F}\(target.model)" }

    private static func decode(_ id: String) -> ModelTarget? {
        let parts = id.split(separator: "\u{1F}", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { return nil }
        return ModelTarget(providerId: parts[0], model: parts[1])
    }

    private func pickerSections(slot: ModelSlot, current: ModelTarget?) -> [ModelPickerSection] {
        var result = [ModelPickerSection(id: "follow", title: nil, rows: [
            ModelPickerRow(id: Self.followID, name: slot == .main ? String(localized: "未设置(沿用 ~/.claude)") : String(localized: "跟随默认"), isSelected: current == nil),
        ])]
        for section in ProviderMenuBuilder.sections(snapshot: model.snapshot, hasKey: { model.hasKey(id: $0) }) {
            let owner = provider(section.providerId)
            result.append(ModelPickerSection(id: section.providerId, title: section.providerName, rows: section.models.map { item in
                let target = ModelTarget(providerId: section.providerId, model: item.id)
                return ModelPickerRow(id: Self.encode(target), name: item.name,
                                      brand: BrandIcon.resolve(modelId: item.id, providerPreset: owner?.presetId, providerName: section.providerName),
                                      copyText: item.id, isSelected: current == target)
            }))
        }
        return result
    }

    /// 下拉按钮的标题:厂商图标 + 模型名(+ 提供商名);目标已失效时标红提示。
    @ViewBuilder
    private func pickerLabel(slot: ModelSlot, current: ModelTarget?) -> some View {
        if let current, let provider = provider(current.providerId) {
            HStack(spacing: 6) {
                BrandIconView(BrandIcon.resolve(modelId: current.model, providerPreset: provider.presetId, providerName: provider.name), size: 14)
                Text(verbatim: provider.displayName(forModel: current.model))
                Text(verbatim: provider.name).foregroundStyle(OMColors.tertiaryText)
                if let problem = problem(provider) { Text(verbatim: "· \(problem)").foregroundStyle(OMColors.warning) }
            }
        } else if current != nil {
            Text("提供商已删除").foregroundStyle(OMColors.warning)
        } else {
            Text(slot == .main ? String(localized: "未设置(沿用 ~/.claude)") : String(localized: "跟随默认")).foregroundStyle(OMColors.secondaryText)
        }
    }

    // MARK: - 辅助任务

    private func utilityRow(_ task: UtilityTask) -> some View {
        let raw = task == .title ? titleChoice : optimizeChoice
        let current = UtilityModelChoice(raw: raw)
        return LabeledContent {
            SlotPickerButton(
                sections: utilitySections(task: task, current: current),
                label: { utilityLabel(current) },
                onPick: { id in
                    let value = id == Self.autoID ? "" : id
                    if task == .title { titleChoice = value } else { optimizeChoice = value }
                }
            )
            .accessibilityLabel(String(localized: "\(task.title) 使用的模型"))
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: task.title)
                Text(verbatim: task.detail).font(OMFonts.caption).foregroundStyle(OMColors.tertiaryText)
            }
        }
    }

    /// 辅助任务的选择列表:自动(标题另有关闭)+ 按提供商分组的全部可用模型;行 ID 即偏好原始值。
    private func utilitySections(task: UtilityTask, current: UtilityModelChoice) -> [ModelPickerSection] {
        var head = [ModelPickerRow(id: Self.autoID, name: String(localized: "自动(Haiku 槽位)"), isSelected: current == .automatic)]
        if task == .title { head.append(ModelPickerRow(id: UtilityModelChoice.off.raw, name: String(localized: "关闭(仅截取首句)"), isSelected: current == .off)) }
        var result = [ModelPickerSection(id: "auto", title: nil, rows: head)]
        for section in ProviderMenuBuilder.sections(snapshot: model.snapshot, hasKey: { model.hasKey(id: $0) }) {
            let owner = provider(section.providerId)
            result.append(ModelPickerSection(id: section.providerId, title: section.providerName, rows: section.models.map { item in
                let choice = UtilityModelChoice.model(providerId: section.providerId, model: item.id)
                return ModelPickerRow(id: choice.raw, name: item.name,
                                      brand: BrandIcon.resolve(modelId: item.id, providerPreset: owner?.presetId, providerName: section.providerName),
                                      copyText: item.id, isSelected: current == choice)
            }))
        }
        return result
    }

    @ViewBuilder
    private func utilityLabel(_ current: UtilityModelChoice) -> some View {
        switch current {
        case .automatic:
            Text("自动(Haiku 槽位)").foregroundStyle(OMColors.secondaryText)
        case .off:
            Text("关闭(仅截取首句)").foregroundStyle(OMColors.secondaryText)
        case .model(let providerId, let modelId):
            if let provider = provider(providerId) {
                HStack(spacing: 6) {
                    BrandIconView(BrandIcon.resolve(modelId: modelId, providerPreset: provider.presetId, providerName: provider.name), size: 14)
                    Text(verbatim: provider.displayName(forModel: modelId))
                    Text(verbatim: provider.name).foregroundStyle(OMColors.tertiaryText)
                    if let problem = problem(provider) { Text(verbatim: "· \(problem)").foregroundStyle(OMColors.warning) }
                }
            } else {
                Text("提供商已删除").foregroundStyle(OMColors.warning)
            }
        }
    }

    // MARK: - 状态

    @ViewBuilder
    private var statusRow: some View {
        if let target = model.snapshot.mapping[.main], let provider = provider(target.providerId) {
            if let problem = problem(provider) {
                Label("默认槽位的提供商不可用:\(problem)。新会话会暂时使用 ~/.claude 的默认配置。", om: "triangle-alert")
                    .font(OMFonts.small).foregroundStyle(OMColors.warning)
            } else {
                Label("映射已启用:新建会话与重新连接使用上面的模型;已打开且空闲的会话会立即刷新。", om: "circle-check")
                    .font(OMFonts.small).foregroundStyle(OMColors.secondaryText)
            }
        } else {
            Label("映射未启用:正在使用 ~/.claude 的默认配置。", om: "info")
                .font(OMFonts.small).foregroundStyle(OMColors.secondaryText)
        }
    }

    private func provider(_ id: String) -> ModelProvider? {
        model.snapshot.providers.first { $0.id == id }
    }

    /// 提供商当前不可用的原因(可用返回 nil)。
    private func problem(_ provider: ModelProvider) -> String? {
        if !provider.isEnabled { return String(localized: "已停用") }
        if provider.requiresKey, !model.hasKey(id: provider.id) { return String(localized: "缺少 API Key") }
        return nil
    }
}

/// 槽位选择按钮:标题 + 弹层列表(选择后自动关闭)。
private struct SlotPickerButton<Label: View>: View {
    let sections: [ModelPickerSection]
    @ViewBuilder let label: () -> Label
    let onPick: (String) -> Void
    @State private var shown = false

    private var flattened: [ModelPickerRow] { ModelPickerSection.flatten(sections) }

    var body: some View {
        Button { shown.toggle() } label: {
            HStack(spacing: 6) {
                label()
                Image.om("chevron-down", size: 10).foregroundStyle(OMColors.tertiaryText)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .omPicker(isPresented: $shown, items: flattened, selectedID: flattened.first(where: \.isSelected)?.id, placeholder: String(localized: "搜索模型"),
                  placement: .below, width: 300, row: { ModelPickRowContent(row: $0) }, onSelect: { row in onPick(row.id) })
    }
}

private extension UtilityTask {
    /// 设置页显示名。
    var title: String {
        switch self {
        case .title: String(localized: "会话标题生成")
        case .optimize: String(localized: "提示词优化")
        }
    }

    /// 设置页说明。
    var detail: String {
        switch self {
        case .title: String(localized: "首条消息后给会话起短标题")
        case .optimize: String(localized: "输入框里的「优化提示词」按钮")
        }
    }
}
