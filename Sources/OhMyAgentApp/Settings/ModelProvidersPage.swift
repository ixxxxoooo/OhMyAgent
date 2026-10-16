// @author ixxxxoooo
// 设置页:模型提供商。左侧提供商列表(搜索、启用开关、密钥状态、添加/导入),右侧详情(连接、模型、高级)。
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
        HStack(spacing: 0) {
            sidebar
                .frame(width: 236)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { model.reload() }
        .sheet(isPresented: $importing) { OpenCodeImportSheet(model: model) { importing = false } }
    }

    // MARK: - 左侧列表

    private var filtered: [ModelProvider] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return model.snapshot.providers }
        return model.snapshot.providers.filter { $0.name.lowercased().contains(needle) || $0.model.lowercased().contains(needle) }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image.om("search", size: 12).foregroundStyle(OMColors.tertiaryText)
                TextField("搜索提供商", text: $query).textFieldStyle(.plain).font(OMFonts.body)
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.06)))
            .padding(10)
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(filtered) { provider in row(provider) }
                    if let pending, !model.snapshot.providers.contains(where: { $0.id == pending.id }) { draftRow(pending) }
                }
                .padding(.horizontal, 8)
            }
            Divider()
            HStack(spacing: 8) {
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
                .fixedSize()
                Spacer()
                Button { importing = true } label: {
                    Label("导入", om: "import").font(OMFonts.small)
                }
                .buttonStyle(.plain)
                .foregroundStyle(OMColors.secondaryText)
                .help("读取本机 OpenCode 的配置,确认后导入提供商与密钥")
            }
            .padding(10)
        }
        .background(Color.primary.opacity(0.03))
    }

    private func row(_ provider: ModelProvider) -> some View {
        listRow(selected: selection == provider.id) {
            select(provider.id)
        } content: {
            HStack(spacing: 8) {
                BrandIconView(BrandIcon.resolve(providerPreset: provider.presetId, providerName: provider.name), size: 15)
                    .foregroundStyle(OMColors.secondaryText)
                    .overlay(alignment: .bottomTrailing) {
                        Circle().fill(statusColor(provider)).frame(width: 6, height: 6)
                            .overlay(Circle().stroke(OMColors.opaqueChrome, lineWidth: 1))
                            .offset(x: 2, y: 2)
                    }
                VStack(alignment: .leading, spacing: 1) {
                    Text(provider.name).font(OMFonts.body).lineLimit(1)
                    Text(provider.model).font(OMFonts.caption).foregroundStyle(OMColors.tertiaryText).lineLimit(1)
                }
                Spacer(minLength: 4)
                Toggle("", isOn: Binding(get: { provider.isEnabled }, set: { model.setEnabled(provider.id, $0) }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .accessibilityLabel(String(localized: "启用 \(provider.name)"))
            }
            .opacity(provider.isEnabled ? 1 : 0.55)
        }
    }

    private func draftRow(_ provider: ModelProvider) -> some View {
        listRow(selected: selection == provider.id) {
            selection = provider.id
        } content: {
            HStack(spacing: 8) {
                Circle().strokeBorder(OMColors.tertiaryText, lineWidth: 1).frame(width: 7, height: 7)
                Text(provider.name).font(OMFonts.body).lineLimit(1)
                Spacer()
                OMTag(String(localized: "未保存"))
            }
        }
    }

    private func listRow<Content: View>(selected: Bool, action: @escaping () -> Void, @ViewBuilder content: () -> Content) -> some View {
        Button(action: action) {
            content()
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Color.accentColor.opacity(0.14) : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 状态点颜色:停用灰、缺密钥橙、可用绿。
    private func statusColor(_ provider: ModelProvider) -> Color {
        if !provider.isEnabled { return OMColors.tertiaryText }
        return (!provider.requiresKey || model.hasKey(id: provider.id)) ? .green : OMColors.warning
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
                Text("选择左侧的提供商进行配置").font(OMFonts.body).foregroundStyle(OMColors.secondaryText)
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
