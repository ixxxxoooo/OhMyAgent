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

    var body: some View {
        Form {
            Section {
                Note("给 Claude Code 里的每个模型槽位指定真实使用的模型。输入框里的模型选择器会显示这里选定的模型;未设置默认槽位时,沿用 ~/.claude 里的配置(也就是你在终端里使用的 claude)。")
                if model.snapshot.providers.isEmpty {
                    Label("还没有模型提供商", om: "info").foregroundStyle(OMColors.secondaryText)
                    Button("去添加提供商") { SettingsRouter.shared.go(.providers) }
                }
            }
            Section("槽位") {
                ForEach(ModelSlot.allCases) { slot in slotRow(slot) }
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

    /// 一个槽位的下拉:跟随默认 + 按提供商分组的全部可用模型。
    private func picker(_ slot: ModelSlot) -> some View {
        let sections = ProviderMenuBuilder.sections(snapshot: model.snapshot, hasKey: { model.hasKey(id: $0) })
        let current = model.snapshot.mapping[slot]
        return Menu {
            Button {
                model.setMapping(slot, nil)
            } label: {
                HStack {
                    Text(slot == .main ? String(localized: "未设置(沿用 ~/.claude)") : String(localized: "跟随默认"))
                    if current == nil { Image.om("checkmark") }
                }
            }
            ForEach(sections) { section in
                Section(section.providerName) {
                    ForEach(section.models) { item in
                        Button {
                            model.setMapping(slot, ModelTarget(providerId: section.providerId, model: item.id))
                        } label: {
                            HStack {
                                Image(nsImage: Self.menuImage(modelId: item.id, provider: provider(section.providerId), name: section.providerName))
                                Text(verbatim: item.name)
                                if current == ModelTarget(providerId: section.providerId, model: item.id) { Image.om("checkmark") }
                            }
                        }
                    }
                }
            }
        } label: {
            pickerLabel(slot: slot, current: current)
        }
        .menuStyle(.button)
        .fixedSize()
        .accessibilityLabel(String(localized: "\(slot.title) 使用的模型"))
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

    private static func menuImage(modelId: String, provider: ModelProvider?, name: String) -> NSImage {
        if case .vector(let key) = BrandIcon.resolve(modelId: modelId, providerPreset: provider?.presetId, providerName: name),
           let image = BrandIconRenderer.nsImage(key, size: 14) { return image }
        return OMIconRenderer.nsImage("cpu", size: 14)
    }
}
