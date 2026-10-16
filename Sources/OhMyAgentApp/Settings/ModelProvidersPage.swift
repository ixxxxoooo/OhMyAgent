// @author ygw
// 设置页:模型提供商(会话级 Anthropic 协议上游 + 模型 + 密钥)。不改动 ~/.claude/settings.json。

import IconKit
import ChatKit
import DesignSystem
import SwiftUI

/// 模型提供商页。
struct ModelProvidersPage: View {
    @State private var model = ProviderSettingsModel()
    @State private var selection: String?
    @State private var draft = ModelProvider(id: "", name: "", baseURL: "", model: "")
    @State private var keyText = ""
    @State private var testing = false
    @State private var testResult: ProviderTestResult?
    @State private var saved = false
    @State private var fetching = false
    @State private var fetchMessage: String?

    var body: some View {
        SettingsForm {
            Section("当前使用") {
                Picker("模型来源", selection: Binding(get: { model.snapshot.active ?? "" }, set: { model.setActive($0.isEmpty ? nil : $0) })) {
                    Text("系统默认(~/.claude 的配置)").tag("")
                    ForEach(model.snapshot.providers) { provider in Text(provider.name).tag(provider.id) }
                }
                Note("选中的提供商对「新建会话与重新连接」生效。每个会话启动时由 OhMyAgent 把地址、模型与密钥交给 Claude Code,不会改动 ~/.claude/settings.json,也不影响终端里的 claude。")
            }
            Section("提供商") {
                ForEach(model.snapshot.providers) { provider in
                    Button { select(provider) } label: {
                        HStack {
                            Text(provider.name)
                            Text(provider.model).font(OMFonts.small).foregroundStyle(OMColors.secondaryText)
                            Spacer()
                            if model.snapshot.active == provider.id { OMTag("使用中") }
                            if !model.hasKey(id: provider.id) { OMTag("缺少 Key") }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(selection == provider.id ? Color.accentColor.opacity(0.12) : Color.clear)
                }
                Menu("添加预设…") {
                    ForEach(ProviderPreset.all) { preset in
                        Button(preset.name) { select(preset.makeProvider(), isNew: true) }
                    }
                    Divider()
                    Button("自定义(Anthropic 兼容端点)") { select(ModelProvider(id: "custom-\(UUID().uuidString.prefix(6))", name: "自定义", baseURL: "https://", model: ""), isNew: true) }
                }
            }
            if selection != nil { editor }
            if let error = model.lastError { Label(error, om: "exclamationmark.triangle").foregroundStyle(OMColors.warning) }
        }
        .onAppear { model.reload() }
    }

    // MARK: - 编辑区

    @ViewBuilder
    private var editor: some View {
        Section("编辑「\(draft.name)」") {
            TextField("名称", text: $draft.name)
            TextField("Anthropic 协议地址", text: $draft.baseURL).textFieldStyle(.roundedBorder)
            TextField("主模型", text: $draft.model).textFieldStyle(.roundedBorder)
            if let preset = ProviderPreset.all.first(where: { $0.id == draft.presetId }) {
                if preset.models.count > 1 {
                    Picker("常用模型", selection: Binding(get: { preset.models.contains(draft.model) ? draft.model : "" }, set: { if !$0.isEmpty { draft.model = $0 } })) {
                        Text("手动输入").tag("")
                        ForEach(preset.models, id: \.self) { Text($0).tag($0) }
                    }
                }
                Note(preset.hint)
            }
            DisclosureGroup("按角色指定模型(可选)") {
                TextField("Opus", text: optional($draft.opusModel)).textFieldStyle(.roundedBorder)
                TextField("Sonnet", text: optional($draft.sonnetModel)).textFieldStyle(.roundedBorder)
                TextField("Haiku(后台任务)", text: optional($draft.haikuModel)).textFieldStyle(.roundedBorder)
                Note("留空则都使用主模型。")
            }
            DisclosureGroup("高级参数(可选)") {
                Toggle("使用 x-api-key 鉴权(Anthropic 官方 API)", isOn: Binding(get: { draft.usesAPIKeyHeader == true }, set: { draft.usesAPIKeyHeader = $0 ? true : nil }))
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
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .background(OMColors.card, in: RoundedRectangle(cornerRadius: 6))
                    Note("每行一个「Name: Value」,对应 ANTHROPIC_CUSTOM_HEADERS;只放进进程环境变量,不写入设置文件。")
                }
                Note("这些参数通过环境变量交给 Claude Code(CLAUDE_CODE_MAX_OUTPUT_TOKENS / CLAUDE_CODE_AUTO_COMPACT_WINDOW / CLAUDE_CODE_EFFORT_LEVEL),留空使用默认值;Claude Code 不支持自定义 temperature。")
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("可选模型").font(OMFonts.small)
                    Spacer()
                    Button("获取模型列表") { Task { await fetchModels() } }.disabled(fetching)
                    if fetching { ProgressView().controlSize(.small) }
                }
                Text((draft.availableModels ?? []).isEmpty ? String(localized: "尚未获取;输入框的模型菜单将只显示主模型。") : (draft.availableModels ?? []).joined(separator: "、"))
                    .font(OMFonts.caption).foregroundStyle(OMColors.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if let fetchMessage { Text(fetchMessage).font(OMFonts.caption).foregroundStyle(OMColors.secondaryText) }
            }
            SecureField(model.hasKey(id: draft.id) ? "API Key(已保存,留空表示不修改)" : "API Key", text: $keyText).textFieldStyle(.roundedBorder)
            Note("密钥保存在 ~/Library/Application Support/OhMyAgent/provider-keys.json(权限 0600),只在启动会话时放进 Claude Code 进程的环境变量,不写入日志。")
            HStack {
                Button("保存") { save() }.keyboardShortcut(.defaultAction)
                Button("测试连接") { Task { await test() } }.disabled(testing)
                if testing { ProgressView().controlSize(.small) }
                if saved { Label("已保存", om: "checkmark.circle").foregroundStyle(OMColors.secondaryText).font(OMFonts.small) }
                Spacer()
                Button("删除", role: .destructive) { remove() }
            }
            if let testResult { resultView(testResult) }
        }
    }

    @ViewBuilder
    private func resultView(_ result: ProviderTestResult) -> some View {
        switch result {
        case .ok(let ms, let reply):
            Label("连接成功(\(ms) ms)\(reply.isEmpty ? "" : ":\(reply)")", om: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let message):
            Label(message, om: "xmark.octagon.fill").foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 操作

    private func optional(_ binding: Binding<String?>) -> Binding<String> {
        Binding(get: { binding.wrappedValue ?? "" }, set: { binding.wrappedValue = $0.isEmpty ? nil : $0 })
    }

    private func select(_ provider: ModelProvider, isNew: Bool = false) {
        var provider = provider
        if isNew, model.snapshot.providers.contains(where: { $0.id == provider.id }) { provider.id = "\(provider.id)-\(UUID().uuidString.prefix(4))" }
        draft = provider
        selection = provider.id
        keyText = ""
        testResult = nil
        saved = false
        fetchMessage = nil
    }

    private func save() {
        guard model.upsert(draft) else { return }
        if !keyText.trimmingCharacters(in: .whitespaces).isEmpty { model.setKey(keyText, id: draft.id); keyText = "" }
        if model.snapshot.active == nil { model.setActive(draft.id) }
        saved = true
    }

    private func test() async {
        testing = true
        testResult = nil
        let key = keyText.trimmingCharacters(in: .whitespaces).isEmpty ? (model.key(id: draft.id) ?? "") : keyText
        testResult = await ProviderTester.test(draft, key: key)
        testing = false
    }

    /// 从 `/v1/models` 获取模型列表并写入草稿(保存后生效)。
    private func fetchModels() async {
        fetching = true
        fetchMessage = nil
        let key = keyText.trimmingCharacters(in: .whitespaces).isEmpty ? (model.key(id: draft.id) ?? "") : keyText
        switch await ProviderModelFetcher.fetch(draft, key: key) {
        case .success(let ids):
            draft.availableModels = ids
            fetchMessage = String(localized: "已获取 \(ids.count) 个模型,点「保存」后生效。")
        case .failure(let error):
            fetchMessage = error.message
        }
        fetching = false
    }

    private func remove() {
        model.remove(id: draft.id)
        selection = nil
    }
}
