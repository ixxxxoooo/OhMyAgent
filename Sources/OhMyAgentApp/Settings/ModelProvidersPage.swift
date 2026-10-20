// @author ixxxxoooo
// 设置页:模型提供商。上下布局:顶部提供商胶囊条(搜索、密钥状态、添加/导入),下方为所选提供商的详情(启用、连接、模型、高级)。
// 这里只管「提供商」本身(地址、协议、密钥、模型清单);哪个 Claude Code 槽位用哪个模型,
// 在「Claude Code 模型映射」页配置。不改动 ~/.claude/settings.json。

import ChatKit
import DesignSystem
import IconKit
import SwiftUI

/// 模型提供商页。
struct ModelProvidersPage: View {
    @State private var model = ProviderSettingsModel()
    /// 选中的提供商 ID,nil 表示未选择
    @State private var selection: String?
    @State private var query = ""
    @State private var importing = false
    /// 新建但尚未保存的草稿
    @State private var pending: ModelProvider?

    var body: some View {
        VStack(spacing: 0) {
            topBar
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            model.reload()
            // 默认展开第一个提供商的配置
            if selection == nil { selection = model.snapshot.providers.first?.id }
        }
        .sheet(isPresented: $importing) { OpenCodeImportSheet(model: model) { importing = false } }
    }

    // MARK: - 顶部提供商条

    private var filtered: [ModelProvider] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return model.snapshot.providers }
        return model.snapshot.providers.filter { $0.name.lowercased().contains(needle) || $0.model.lowercased().contains(needle) }
    }

    /// 当前选中的提供商(含未保存草稿)。
    private var selectedProvider: ModelProvider? {
        guard let id = selection else { return nil }
        return pending?.id == id ? pending : model.snapshot.providers.first { $0.id == id }
    }

    /// 选中的是否为尚未保存的草稿。
    private var isDraftSelected: Bool {
        guard let id = selection else { return false }
        return !model.snapshot.providers.contains { $0.id == id }
    }

    /// 顶部:横向提供商胶囊 + 搜索(提供商较多时)+ 添加 + 导入。
    private var topBar: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(filtered) { provider in chip(provider) }
                    if let pending, !model.snapshot.providers.contains(where: { $0.id == pending.id }) { draftChip(pending) }
                }
                .padding(.vertical, 2)
            }
            if model.snapshot.providers.count > 6 {
                HStack(spacing: 6) {
                    Image.om("search", size: 12).foregroundStyle(OMColors.tertiaryText)
                    TextField("搜索提供商", text: $query).textFieldStyle(.plain).font(OMFonts.small)
                }
                .padding(.horizontal, 8)
                .frame(width: 140, height: 24)
                .background(RoundedRectangle(cornerRadius: OMRadius.tag).fill(OMColors.hoverFill))
            }
            Menu {
                ForEach(ProviderPreset.all) { preset in
                    Button(preset.name) { startNew(preset.makeProvider()) }
                }
                Divider()
                Button("自定义(Anthropic 协议)") { startNew(Self.customDraft(.anthropic)) }
                Button("自定义(OpenAI 协议)") { startNew(Self.customDraft(.openai)) }
            } label: {
                Label("添加", om: "plus").font(OMFonts.small)
            }
            .menuStyle(.button)
            .controlSize(.small)
            .fixedSize()
            Button { importing = true } label: {
                Label("导入", om: "import")
            }
            .buttonStyle(.omSecondary)
            .omTooltip("读取本机 OpenCode 的配置,确认后导入提供商与密钥")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(OMColors.surface)
    }

    /// 提供商胶囊:品牌图标 + 名称 + 状态点。
    private func chip(_ provider: ModelProvider) -> some View {
        chipButton(selected: selection == provider.id) {
            select(provider.id)
        } content: {
            HStack(spacing: 6) {
                BrandIconView(BrandIcon.resolve(providerPreset: provider.presetId, providerName: provider.name), size: 14)
                    .foregroundStyle(OMColors.secondaryText)
                Text(provider.name).font(OMFonts.small).lineLimit(1)
                Circle().fill(statusColor(provider)).frame(width: 6, height: 6)
            }
            .opacity(provider.isEnabled ? 1 : 0.55)
        }
        .accessibilityLabel(provider.name)
    }

    private func draftChip(_ provider: ModelProvider) -> some View {
        chipButton(selected: selection == provider.id) {
            selection = provider.id
        } content: {
            HStack(spacing: 6) {
                Circle().strokeBorder(OMColors.tertiaryText, lineWidth: 1).frame(width: 7, height: 7)
                Text(provider.name).font(OMFonts.small).lineLimit(1)
                OMTag(String(localized: "未保存"))
            }
        }
    }

    private func chipButton<Content: View>(selected: Bool, action: @escaping () -> Void, @ViewBuilder content: () -> Content) -> some View {
        Button(action: action) {
            content()
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(OMPillShape().fill(selected ? OMColors.selectedFill : OMColors.subtleFill))
                                .contentShape(OMPillShape())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    /// 状态点颜色:停用灰、缺密钥橙、可用绿。
    private func statusColor(_ provider: ModelProvider) -> Color {
        if !provider.isEnabled { return OMColors.tertiaryText }
        return (!provider.requiresKey || model.hasKey(id: provider.id)) ? OMColors.success : OMColors.warning
    }

    // MARK: - 右侧详情

    @ViewBuilder
    private var detail: some View {
        if let id = selection, let provider = pending?.id == id ? pending : model.snapshot.providers.first(where: { $0.id == id }) {
            ProviderDetailView(model: model, initial: provider, isNew: !model.snapshot.providers.contains(where: { $0.id == id })) { savedId in
                pending = nil
                selection = savedId
            } onDelete: {
                pending = nil
                selection = nil
            }
            .id(id)
        } else {
            VStack(spacing: 8) {
                Image.om("server", size: 28).foregroundStyle(OMColors.tertiaryText)
                Text("选择上方的提供商进行配置").font(OMFonts.body).foregroundStyle(OMColors.secondaryText)
                Text("这里只配置提供商本身;让 Claude Code 的默认/Opus/Sonnet/Haiku 使用哪个模型,请到「Claude Code 模型映射」页选择。")
                    .font(OMFonts.caption).foregroundStyle(OMColors.tertiaryText)
                    .multilineTextAlignment(.center).frame(maxWidth: 360)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - 操作

    private func select(_ id: String) {
        pending = nil
        selection = id
    }

    private func startNew(_ provider: ModelProvider) {
        let unique = model.makeUnique(provider)
        pending = unique
        selection = unique.id
    }

    /// 自定义提供商草稿。
    static func customDraft(_ kind: ProviderProtocol) -> ModelProvider {
        ModelProvider(id: "custom-\(UUID().uuidString.prefix(6).lowercased())", name: String(localized: "自定义"), baseURL: "https://", model: "",
                      protocolKind: kind == .openai ? .openai : nil)
    }
}
