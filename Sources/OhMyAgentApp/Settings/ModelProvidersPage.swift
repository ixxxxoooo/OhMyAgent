// @author ixxxxoooo
// 设置页:模型提供商。左侧提供商列表(搜索、启用开关、密钥状态、添加/导入),右侧详情(连接、模型、高级)。
// 不改动 ~/.claude/settings.json;提供商经 ACP `_meta` 在会话启动时交给 Claude Code,
// OpenAI 协议的提供商经本机内置协议代理转换。

import ChatKit
import DesignSystem
import IconKit
import SwiftUI

/// 模型提供商页。
struct ModelProvidersPage: View {
    @State private var model = ProviderSettingsModel()
    /// 选中的提供商 ID;空串表示「系统默认」,nil 表示未选择
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
                    systemRow
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

    private var systemRow: some View {
        listRow(selected: selection == "") {
            select("")
        } content: {
            HStack(spacing: 8) {
                Image.om("server", size: 13).foregroundStyle(OMColors.secondaryText)
                Text("系统默认").font(OMFonts.body)
                Spacer()
                if model.snapshot.active == nil { OMTag(String(localized: "默认")) }
            }
        }
    }

    private func row(_ provider: ModelProvider) -> some View {
        listRow(selected: selection == provider.id) {
            select(provider.id)
        } content: {
            HStack(spacing: 8) {
                Circle().fill(statusColor(provider)).frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text(provider.name).font(OMFonts.body).lineLimit(1)
                    Text(provider.model).font(OMFonts.caption).foregroundStyle(OMColors.tertiaryText).lineLimit(1)
                }
                Spacer(minLength: 4)
                if model.snapshot.active == provider.id { OMTag(String(localized: "默认")) }
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
        if selection == "" {
            SystemDefaultDetail(model: model)
        } else if let id = selection, let provider = pending?.id == id ? pending : model.snapshot.providers.first(where: { $0.id == id }) {
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
                Text("「默认」用于新建会话;已启用且配置了密钥的提供商都会出现在输入框的模型菜单里,在菜单里切换只影响当前会话。")
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

/// 「系统默认」详情。
private struct SystemDefaultDetail: View {
    let model: ProviderSettingsModel

    var body: some View {
        Form {
            Section("系统默认") {
                Note("沿用 ~/.claude 里的配置(含你在终端里使用的模型与登录凭据)。OhMyAgent 不会改动该文件,也不影响终端里的 claude。")
                if model.snapshot.active == nil {
                    Label("当前全局默认", om: "check").foregroundStyle(OMColors.secondaryText)
                } else {
                    Button("设为全局默认") { model.setActive(nil) }
                }
                Note("全局默认对「新建会话与重新连接」生效;已打开的会话可以在输入框的模型菜单里单独切换,只影响当前会话。")
            }
        }
        .formStyle(.grouped)
    }
}
