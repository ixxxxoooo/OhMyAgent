// @author ygw
// 设置页:模型提供商(会话级 Anthropic 协议上游 + 模型 + 密钥)。不改动 ~/.claude/settings.json。

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

    var body: some View {
        SettingsForm {
            Section("当前使用") {
                Picker("模型来源", selection: Binding(get: { model.snapshot.active ?? "" }, set: { model.setActive($0.isEmpty ? nil : $0) })) {
                    Text("系统默认(~/.claude 的配置)").tag("")
                    ForEach(model.snapshot.providers) { provider in Text(provider.name).tag(provider.id) }
                }
                Note("选中的提供商对**新建会话与重新连接**生效。每个会话启动时由 OhMyAgent 把地址、模型与密钥交给 Claude Code,不会改动 ~/.claude/settings.json,也不影响终端里的 claude。")
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
            if let error = model.lastError { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(OMColors.warning) }
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
            SecureField(model.hasKey(id: draft.id) ? "API Key(已保存,留空表示不修改)" : "API Key", text: $keyText).textFieldStyle(.roundedBorder)
            Note("密钥保存在 ~/Library/Application Support/OhMyAgent/provider-keys.json(权限 0600),只在启动会话时放进 Claude Code 进程的环境变量,不写入日志。")
            HStack {
                Button("保存") { save() }.keyboardShortcut(.defaultAction)
                Button("测试连接") { Task { await test() } }.disabled(testing)
                if testing { ProgressView().controlSize(.small) }
                if saved { Label("已保存", systemImage: "checkmark.circle").foregroundStyle(OMColors.secondaryText).font(OMFonts.small) }
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
            Label("连接成功(\(ms) ms)\(reply.isEmpty ? "" : ":\(reply)")", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
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

    private func remove() {
        model.remove(id: draft.id)
        selection = nil
    }
}
