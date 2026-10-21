// @author ixxxxoooo
// 设置页:Agent 与模型、权限。均写回 settings.json。

import IconKit
import AppKit
import ChatKit
import ClaudeConfigKit
import DesignSystem
import SwiftUI
import WorkbenchKit

/// Agent 与模型。
struct AgentModelPage: View {
    @Bindable var model: ClaudeSettingsModel

    @AppStorage(WarmMode.preferenceKey) private var warmMode = WarmMode.smart.rawValue

    private let aliases = ["", "opus", "sonnet", "haiku", "opusplan"]

    var body: some View {
        SettingsForm {
            Section { ScopeHeader(model: model) }
            Section("模型") {
                HStack {
                    TextField("默认模型", text: model.stringBinding(["model"]), prompt: Text("留空使用 Claude Code 默认"))
                    Menu("常用") {
                        ForEach(aliases, id: \.self) { alias in
                            Button(alias.isEmpty ? String(localized: "默认") : alias) { model.set(["model"], alias.isEmpty ? nil : alias) }
                        }
                    }
                    .fixedSize()
                }
                if let effective = model.effective(["model"]), effective.scope != model.scope {
                    Note("当前生效的是\(effective.scope.displayName)层的值:\(effective.value)")
                }
                Toggle("默认开启扩展思考", isOn: model.boolBinding(["alwaysThinkingEnabled"]))
                LabeledContent("思考预算(tokens)") {
                    TextField("", text: model.envBinding("MAX_THINKING_TOKENS"), prompt: Text("默认")).frame(width: 110).multilineTextAlignment(.trailing)
                }
                LabeledContent("自动压缩阈值(%)") {
                    TextField("", text: model.envBinding("CLAUDE_AUTOCOMPACT_PCT_OVERRIDE"), prompt: Text("默认")).frame(width: 110).multilineTextAlignment(.trailing)
                }
                Note("思考预算与自动压缩阈值通过环境变量 MAX_THINKING_TOKENS / CLAUDE_AUTOCOMPACT_PCT_OVERRIDE 写入 settings.json 的 env,新会话生效。")
            }
            Section("连接预热") {
                Picker("预热模式", selection: $warmMode) {
                    Text("关闭").tag(WarmMode.off.rawValue)
                    Text("智能").tag(WarmMode.smart.rawValue)
                    Text("全部").tag(WarmMode.all.rawValue)
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("预热模式")
                Note("智能:启动后稍作等待,提前连好当前项目最近用过的引擎,并在打开引擎选择器时预热其余引擎;全部:启动后依次连好所有已启用的引擎(最多 4 个)。切换引擎时直接认领已连好的会话。")
                Note("预热的代价:每个引擎都是一个常驻进程(内存与电量),并各自挂载 MCP 与 Bridge;启动时多个进程同时握手会抢 CPU,所以只会逐个、延迟进行;需要登录的引擎可能在后台弹出授权;预热失败 5 分钟内不会重试。对启动速度不敏感时可选「关闭」。")
            }
            Section("输出风格") {
                TextField("Output style", text: model.stringBinding(["outputStyle"]), prompt: Text("Default / Explanatory / Learning 或自定义名称"))
            }
            Section("API 提供方") {
                LabeledContent("提供方", value: providerName)
                TextField("apiKeyHelper 脚本", text: model.stringBinding(["apiKeyHelper"]), prompt: Text("可选:输出 API Key 的脚本路径"))
                Note("提供方由环境变量决定(CLAUDE_CODE_USE_BEDROCK / VERTEX / FOUNDRY),此处只读展示。OhMyAgent 不会读取或保存你的凭据。")
            }
            Section("默认 Agent") {
                LabeledContent("当前", value: Toolchain.defaultDescriptor().name)
                Note("新对话沿用你上次选择的 Agent、模型、思考强度与权限模式;从未选择过时使用「Agent 扩展」页设置的默认 Agent。可在该页登记其他 ACP Agent。")
            }
        }
    }

    private var providerName: String {
        let env = ProcessInfo.processInfo.environment.merging(model.dictionary(["env"])) { _, new in new }
        func on(_ key: String) -> Bool { ["1", "true"].contains(env[key]?.lowercased() ?? "") }
        if on("CLAUDE_CODE_USE_BEDROCK") { return "Amazon Bedrock" }
        if on("CLAUDE_CODE_USE_VERTEX") { return "Google Vertex AI" }
        if on("CLAUDE_CODE_USE_FOUNDRY") { return "Microsoft Foundry" }
        return "Anthropic(firstParty)"
    }
}

/// 权限。
struct PermissionsPage: View {
    @Bindable var model: ClaudeSettingsModel
    @State private var pendingMode: String?
    @State private var testTool = "Bash"
    @State private var testArgument = ""

    private var store: PermissionsStore { PermissionsStore(paths: model.paths) }
    private let modes: [(String, String)] = [("", String(localized: "默认(逐次询问)")), ("acceptEdits", String(localized: "自动接受编辑")), ("plan", String(localized: "计划模式")), ("dontAsk", String(localized: "不再询问(仅执行允许规则)")), ("bypassPermissions", String(localized: "跳过所有权限(危险)"))]

    var body: some View {
        SettingsForm {
            Section { ScopeHeader(model: model) }
            Section("默认模式") {
                Picker("默认权限模式", selection: Binding(
                    get: { model.string(["permissions", "defaultMode"]) ?? "" },
                    set: { value in
                        if value == "bypassPermissions" { pendingMode = value } else { model.set(["permissions", "defaultMode"], value.isEmpty ? nil : value) }
                    })) {
                    ForEach(modes, id: \.0) { Text($0.1).tag($0.0) }
                }
                Toggle("禁止启用「跳过所有权限」模式", isOn: Binding(
                    get: { model.string(["permissions", "disableBypassPermissionsMode"]) == "disable" },
                    set: { model.set(["permissions", "disableBypassPermissionsMode"], $0 ? "disable" : nil) }))
            }
            ForEach(PermissionBehavior.allCases) { behavior in
                Section("\(behavior.displayName)规则") { RuleListEditor(model: model, behavior: behavior) }
            }
            Section("额外可访问目录") { DirectoryListEditor(model: model) }
            Section("沙盒") {
                Toggle("启用 Bash 沙盒", isOn: model.boolBinding(["sandbox", "enabled"]))
                Note("沙盒将命令限制在工作区与允许的网络范围内。详细的文件与网络白名单请在 settings.json 的 sandbox 字段中配置。")
            }
            Section("测试匹配") {
                HStack {
                    TextField("工具", text: $testTool).frame(width: 130)
                    TextField("命令 / 路径 / URL", text: $testArgument)
                }
                Text(testResult).font(OMFonts.small).foregroundStyle(OMColors.secondaryText)
            }
        }
        .confirmationDialog("启用「跳过所有权限」?", isPresented: Binding(get: { pendingMode != nil }, set: { if !$0 { pendingMode = nil } })) {
            Button("我了解风险,启用", role: .destructive) { model.set(["permissions", "defaultMode"], "bypassPermissions"); pendingMode = nil }
        } message: {
            Text("Claude 将不经确认执行任何工具,包括删除文件与运行命令。仅建议在隔离环境中使用。")
        }
    }

    private var testResult: String {
        _ = model.revision
        guard let hit = store.evaluate(tool: testTool, argument: testArgument.isEmpty ? nil : testArgument) else { return String(localized: "没有规则命中,将按默认模式处理。") }
        return String(localized: "命中\(hit.behavior.displayName)规则 \(hit.rule)(\(hit.scope.displayName)层)")
    }
}

/// 单类规则的列表编辑。
struct RuleListEditor: View {
    @Bindable var model: ClaudeSettingsModel
    let behavior: PermissionBehavior
    @State private var draft = ""

    private var rules: [String] { PermissionsStore(paths: model.paths).rules(behavior, in: model.scope) }
    private var problem: String? { draft.isEmpty ? nil : PermissionRule.validate(draft) }

    var body: some View {
        ForEach(rules, id: \.self) { rule in
            HStack {
                Text(rule).font(OMFonts.mono).textSelection(.enabled)
                Spacer()
                Button { remove(rule) } label: { Image.om("minus.circle") }.buttonStyle(.omPlain).accessibilityLabel("删除规则 \(rule)")
            }
        }
        HStack {
            TextField("例如 Bash(npm run test:*) 或 Read(./.env)", text: $draft).font(OMFonts.mono).onSubmit(add)
            Button("添加", action: add).disabled(draft.isEmpty || problem != nil)
        }
        if let problem { Label(problem, om: "exclamationmark.circle").font(OMFonts.caption).foregroundStyle(OMColors.warning) }
    }

    private func add() {
        guard problem == nil, !draft.isEmpty else { return }
        write(rules + [draft.trimmingCharacters(in: .whitespaces)])
        draft = ""
    }

    private func remove(_ rule: String) { write(rules.filter { $0 != rule }) }

    private func write(_ list: [String]) {
        do { try PermissionsStore(paths: model.paths).setRules(list, behavior, in: model.scope); model.lastError = nil }
        catch { model.lastError = error.localizedDescription }
        model.refresh()
    }
}

/// 额外目录列表编辑。
struct DirectoryListEditor: View {
    @Bindable var model: ClaudeSettingsModel

    private var directories: [String] { model.list(["permissions", "additionalDirectories"]) }

    var body: some View {
        ForEach(directories, id: \.self) { path in
            HStack {
                Text(path).font(OMFonts.mono).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button { model.set(["permissions", "additionalDirectories"], directories.filter { $0 != path }.nilIfEmpty) } label: { Image.om("minus.circle") }
                    .buttonStyle(.omPlain).accessibilityLabel("移除目录 \(path)")
            }
        }
        Button("添加目录…") {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            if panel.runModal() == .OK, let url = panel.url, !directories.contains(url.path) {
                model.set(["permissions", "additionalDirectories"], directories + [url.path])
            }
        }
    }
}

extension Array {
    /// 空数组返回 nil,便于"空即删除键"。
    var nilIfEmpty: [Element]? { isEmpty ? nil : self }
}
