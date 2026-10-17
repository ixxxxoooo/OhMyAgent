// @author ixxxxoooo
// 模型提供商详情:连接(名称/协议/地址/密钥)、模型(重命名、启停、主模型、获取列表)、高级。

import ChatKit
import DesignSystem
import IconKit
import SwiftUI

/// 提供商详情编辑区。
struct ProviderDetailView: View {
    let model: ProviderSettingsModel
    let isNew: Bool
    let onSaved: (String) -> Void
    let onDelete: () -> Void

    @State private var draft: ModelProvider
    @State private var keyText: String
    @State private var testing = false
    @State private var testResult: ProviderTestResult?
    @State private var saved = false
    @State private var showFetch = false
    @State private var newModelId = ""
    @State private var confirmDelete = false

    /// 创建详情。
    /// - Parameters:
    ///   - model: 设置模型
    ///   - initial: 初始提供商
    ///   - isNew: 是否新建(尚未保存)
    ///   - onSaved: 保存后回调(参数为提供商 ID)
    ///   - onDelete: 删除或放弃后回调
    init(model: ProviderSettingsModel, initial: ModelProvider, isNew: Bool, onSaved: @escaping (String) -> Void, onDelete: @escaping () -> Void) {
        self.model = model
        self.isNew = isNew
        self.onSaved = onSaved
        self.onDelete = onDelete
        _draft = State(initialValue: initial)
        _keyText = State(initialValue: model.key(id: initial.id) ?? "")
    }

    private var preset: ProviderPreset? { ProviderPreset.all.first { $0.id == draft.presetId } }

    var body: some View {
        Form {
            connectionSection
            modelsSection
            advancedSection
            actionsSection
        }
        .formStyle(.grouped)
        .settingsSurface()
        .sheet(isPresented: $showFetch) {
            ModelFetchSheet(provider: draft, key: keyText, existing: Set(draft.modelList.map(\.id))) { ids in
                draft.mergeModels(ids)
                showFetch = false
            } onCancel: { showFetch = false }
        }
        .confirmationDialog("删除「\(draft.name)」?", isPresented: $confirmDelete) {
            Button("删除", role: .destructive) {
                if !isNew { model.remove(id: draft.id) }
                onDelete()
            }
        } message: {
            Text("提供商配置与已保存的密钥都会被删除。")
        }
    }

    // MARK: - 连接

    private var connectionSection: some View {
        Section("连接") {
            TextField("名称", text: $draft.name)
            Picker("协议", selection: Binding(get: { draft.protocolKind ?? .anthropic }, set: { draft.protocolKind = $0 == .openai ? .openai : nil })) {
                Text("Anthropic").tag(ProviderProtocol.anthropic)
                Text("OpenAI(经内置代理转换)").tag(ProviderProtocol.openai)
            }
            TextField(draft.isOpenAIProtocol ? "OpenAI 协议地址(含 /v1)" : "Anthropic 协议地址", text: $draft.baseURL).textFieldStyle(.roundedBorder)
            LabeledContent(draft.requiresKey ? "API Key" : "API Key(可选)") {
                SecretField(placeholder: draft.requiresKey ? "API Key" : String(localized: "无需密钥时可留空"), text: $keyText)
            }
            if let preset { Note(preset.hint) }
            if draft.isOpenAIProtocol {
                Note("OpenAI 协议由本机 127.0.0.1 上的内置代理转换成 Anthropic 协议;真实地址与密钥只保存在 OhMyAgent 进程内,不会交给 Claude Code。")
            }
            Note("密钥保存在 ~/Library/Application Support/OhMyAgent/provider-keys.json(权限 0600),不写入日志与 ~/.claude。")
            HStack {
                Button("测试连接") { Task { await test() } }.disabled(testing)
                if testing { OMSpinner(.small) }
                Spacer()
                Button("去模型映射中使用…") { if save() { SettingsRouter.shared.go(.modelMapping) } }
                    .help("把这个提供商的模型映射到 Claude Code 的默认/Opus/Sonnet/Haiku 槽位")
            }
            if let testResult { resultView(testResult) }
        }
    }

    // MARK: - 模型

    private var modelsSection: some View {
        Section("模型") {
            LabeledContent("默认模型") {
                TextField("", text: $draft.model, prompt: Text("模型 ID")).labelsHidden().textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
            }
            ForEach(draft.modelList) { item in modelRow(item) }
            HStack {
                TextField("", text: $newModelId, prompt: Text("手动添加模型 ID")).labelsHidden().textFieldStyle(.roundedBorder).onSubmit(addModel)
                Button("添加", action: addModel).disabled(newModelId.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            HStack {
                Button { showFetch = true } label: { Label("获取模型列表", om: "cloud-download") }
                Spacer()
            }
            Note("勾选的模型可在「Claude Code 模型映射」里选择;名称可直接修改,仅影响显示。")
        }
    }

    private func modelRow(_ item: ProviderModel) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: modelBinding(item.id, \.enabled)).labelsHidden().toggleStyle(.checkbox)
                .accessibilityLabel(String(localized: "可用于模型映射 \(item.id)"))
            BrandIconView(BrandIcon.resolve(modelId: item.id, providerPreset: draft.presetId, providerName: draft.name), size: 15)
            VStack(alignment: .leading, spacing: 1) {
                TextField("", text: Binding(
                    get: { draft.modelList.first { $0.id == item.id }?.displayName ?? "" },
                    set: { value in updateModel(item.id) { $0.displayName = value.isEmpty ? nil : value } }
                ), prompt: Text(item.id))
                .labelsHidden()
                .textFieldStyle(.plain).font(OMFonts.body).multilineTextAlignment(.leading)
                if item.name != item.id { Text(item.id).font(OMFonts.caption).foregroundStyle(OMColors.tertiaryText) }
            }
            ModelCopyButton(text: item.id)
            Spacer(minLength: 4)
            Button { draft.model = item.id } label: {
                Image.om("star", size: 13).foregroundStyle(draft.model == item.id ? OMColors.warning : OMColors.tertiaryText)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help(draft.model == item.id ? "当前默认模型" : "设为默认模型")
            .accessibilityLabel(String(localized: "设为默认模型"))
            Button { removeModel(item.id) } label: {
                Image.om("trash", size: 13).foregroundStyle(OMColors.tertiaryText).frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help("删除")
            .accessibilityLabel(String(localized: "删除模型"))
        }
    }

    // MARK: - 高级

    private var advancedSection: some View {
        Section {
            DisclosureGroup("高级参数(可选)") {
                if !draft.isOpenAIProtocol {
                    Toggle("使用 x-api-key 鉴权(Anthropic 官方 API)", isOn: Binding(get: { draft.usesAPIKeyHeader == true }, set: { draft.usesAPIKeyHeader = $0 ? true : nil }))
                } else {
                    Toggle("无需 API Key", isOn: Binding(get: { draft.keyOptional == true }, set: { draft.keyOptional = $0 ? true : nil }))
                }
                Toggle("OpenCode 兼容请求头", isOn: Binding(get: { draft.opencodeCompat == true }, set: { draft.opencodeCompat = $0 ? true : nil }))
                LabeledContent("最大输出 token") {
                    TextField("默认", value: $draft.maxOutputTokens, format: .number).frame(width: 100).multilineTextAlignment(.trailing)
                }
                LabeledContent("上下文窗口(token)") {
                    TextField("默认", value: $draft.contextWindow, format: .number).frame(width: 100).multilineTextAlignment(.trailing)
                }
                Picker("思考强度", selection: Binding(get: { draft.effort ?? "" }, set: { draft.effort = $0.isEmpty ? nil : $0 })) {
                    Text("默认").tag("")
                    Text("低").tag("low")
                    Text("中").tag("medium")
                    Text("高").tag("high")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("自定义请求头").font(OMFonts.small)
                    TextEditor(text: optional($draft.customHeaders))
                        .font(OMFonts.monoSmall)
                        .frame(height: 60)
                        .settingsEditorStyle()
                    Note("每行一个「Name: Value」;Anthropic 协议经 ANTHROPIC_CUSTOM_HEADERS 交给 Claude Code(只进进程环境变量),OpenAI 协议由内置代理附带。")
                }
                Note("这些参数通过环境变量交给 Claude Code(CLAUDE_CODE_MAX_OUTPUT_TOKENS / CLAUDE_CODE_AUTO_COMPACT_WINDOW / CLAUDE_CODE_EFFORT_LEVEL),留空使用默认值;Claude Code 不支持自定义 temperature。")
            }
        }
    }

    private var actionsSection: some View {
        Section {
            HStack {
                Button("保存") { _ = save() }.keyboardShortcut(.defaultAction)
                if saved { Label("已保存", om: "checkmark.circle").foregroundStyle(OMColors.secondaryText).font(OMFonts.small) }
                if let error = model.lastError { Label(error, om: "exclamationmark.triangle").foregroundStyle(OMColors.warning).font(OMFonts.small) }
                Spacer()
                Button(isNew ? "放弃" : "删除", role: .destructive) { isNew ? onDelete() : (confirmDelete = true) }
            }
            if saved { Note("对「新建会话与重新连接」生效;已打开的会话请在输入框的模型菜单里切换。") }
        }
    }

    @ViewBuilder
    private func resultView(_ result: ProviderTestResult) -> some View {
        switch result {
        case .ok(let ms, let reply):
            Label("连接成功(\(ms) ms)\(reply.isEmpty ? "" : ":\(reply)")", om: "checkmark.circle.fill").foregroundStyle(OMColors.success)
        case .failed(let message):
            Label(message, om: "xmark.octagon.fill").foregroundStyle(OMColors.danger).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 数据操作

    private func optional(_ binding: Binding<String?>) -> Binding<String> {
        Binding(get: { binding.wrappedValue ?? "" }, set: { binding.wrappedValue = $0.isEmpty ? nil : $0 })
    }

    /// 修改指定模型条目(先把推导出的清单固化到 `models`)。
    private func updateModel(_ id: String, _ change: (inout ProviderModel) -> Void) {
        var list = draft.modelList
        guard let index = list.firstIndex(where: { $0.id == id }) else { return }
        change(&list[index])
        draft.models = list
        draft.availableModels = nil
    }

    private func modelBinding(_ id: String, _ keyPath: WritableKeyPath<ProviderModel, Bool>) -> Binding<Bool> {
        Binding(get: { draft.modelList.first { $0.id == id }?[keyPath: keyPath] ?? false }, set: { value in updateModel(id) { $0[keyPath: keyPath] = value } })
    }

    private func addModel() {
        let id = newModelId.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return }
        draft.mergeModels([id])
        if draft.model.isEmpty { draft.model = id }
        newModelId = ""
    }

    private func removeModel(_ id: String) {
        draft.models = draft.modelList.filter { $0.id != id }
        draft.availableModels = nil
        if draft.model == id { draft.model = draft.models?.first?.id ?? "" }
    }

    /// 保存提供商与密钥。
    /// - Returns: 成功返回 true
    @discardableResult
    private func save() -> Bool {
        var provider = draft
        // 主模型必须在清单里(便于菜单展示与重命名)
        if !provider.model.isEmpty, !provider.modelList.contains(where: { $0.id == provider.model }) { provider.mergeModels([provider.model]) }
        guard model.upsert(provider) else { return false }
        model.setKey(keyText, id: provider.id)
        // 第一次添加的可用提供商:自动成为默认槽位,免得用户还得再去映射页点一遍
        if isNew, model.snapshot.mapping.isEmpty, !provider.model.isEmpty, !provider.requiresKey || model.hasKey(id: provider.id) {
            model.setMapping(.main, ModelTarget(providerId: provider.id, model: provider.model))
        }
        draft = model.snapshot.providers.first { $0.id == provider.id } ?? provider
        saved = true
        onSaved(provider.id)
        return true
    }

    private func test() async {
        testing = true
        testResult = nil
        testResult = await ProviderTester.test(draft, key: keyText)
        testing = false
    }
}
