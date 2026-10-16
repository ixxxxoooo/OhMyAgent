// @author ixxxxoooo
// 设置页:Agent 扩展(Agent 注册表、Agent-as-MCP、OhMyAgent Bridge)。均写回 agents.json。

import IconKit
import AppKit
import AgentHost
import ChatKit
import DesignSystem
import SwiftUI

/// 常用 ACP Agent 预设(命令以各自官方文档为准,添加后可在表单中修改)。
struct AgentPreset {
    var id: String
    var name: String
    var command: String
    var args: [String]
    var summary: String

    /// 固定的 pi-acp 版本:npx 不带版本号会随时拉到最新版,适配器行为变化会让 Pi 会话无征兆地异常(中断、重复通知等)。
    static let piAcpVersion = "0.0.34"

    static let all: [AgentPreset] = [
        AgentPreset(id: "gemini", name: "Gemini CLI", command: "gemini", args: ["--experimental-acp"], summary: String(localized: "Google Gemini CLI 的 ACP 模式")),
        AgentPreset(id: "goose", name: "Goose", command: "goose", args: ["acp"], summary: String(localized: "Block 的 Goose Agent")),
        AgentPreset(id: "opencode", name: "OpenCode", command: "opencode", args: ["acp"], summary: String(localized: "OpenCode 的 ACP 模式")),
        AgentPreset(id: "pi", name: "Pi", command: "npx", args: ["-y", "pi-acp@\(piAcpVersion)"], summary: String(localized: "Pi 编码 Agent(pi-acp 适配器,经 npx 运行并固定版本,需已安装 Node.js;若已全局安装 pi-acp 会优先使用)")),
        AgentPreset(id: "codex", name: String(localized: "Codex(codex-acp 适配器)"), command: "codex-acp", args: [], summary: String(localized: "需先安装 codex-acp 适配器")),
    ]
}

/// 编辑中的自定义 Agent。
struct AgentDraft: Identifiable {
    var id: String
    var name = ""
    var command = ""
    var args = ""
    var env = ""
    var summary = ""
    var isNew = true

    init(id: String = "") { self.id = id }

    init(_ agent: AgentDescriptor) {
        id = agent.id
        name = agent.name
        command = agent.command ?? ""
        args = agent.args.joined(separator: " ")
        env = agent.env.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
        summary = agent.summary ?? ""
        isNew = false
    }

    init(_ preset: AgentPreset, path: String = ProcessInfo.processInfo.environment["PATH"] ?? "") {
        id = preset.id
        name = preset.name
        command = preset.command
        args = preset.args.joined(separator: " ")
        summary = preset.summary
        // Pi:本机已全局安装 pi-acp 时直接用它(启动更快、不依赖网络,版本由用户自己管理)
        if preset.id == "pi", GenericACPProvider.resolve("pi-acp", path: path) != nil {
            command = "pi-acp"
            args = ""
        }
    }

    /// 转为描述符(参数按空白拆分,环境变量按行解析)。
    func descriptor(enabled: Bool) -> AgentDescriptor {
        var environment: [String: String] = [:]
        for line in env.split(separator: "\n") {
            guard let index = line.firstIndex(of: "=") else { continue }
            let key = line[..<index].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { environment[key] = String(line[line.index(after: index)...]) }
        }
        return AgentDescriptor(id: id.trimmingCharacters(in: .whitespaces), name: name.isEmpty ? id : name, kind: .genericACP,
                               command: command.trimmingCharacters(in: .whitespaces), args: args.split(separator: " ").map(String.init),
                               env: environment, enabled: enabled, summary: summary.isEmpty ? nil : summary)
    }
}

/// Agent 扩展。
struct AgentExtensionsPage: View {
    @State private var registry = AgentRegistryModel.shared
    @State private var draft: AgentDraft?
    @State private var mcpDraft: AgentMCPEntry?
    @State private var path = ""
    @AppStorage(ClientPrefs.Key.showAgentNotify) private var showAgentNotify = true

    var body: some View {
        SettingsForm {
            agentsSection
            Section("Agent 通知") {
                Toggle("显示第三方 Agent 的通知行", isOn: $showAgentNotify)
                Note("Pi 等适配器会把扩展通知(如 pi-tps 的「TPS …」)混在消息里发出。开启时以淡色小字单独成行,关闭则隐藏;警告与错误级别始终显示。")
            }
            mcpSection
            bridgeSection
            Section("配置文件") {
                LabeledContent("agents.json") {
                    HStack {
                        Text(registry.fileURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(OMFonts.small).foregroundStyle(OMColors.secondaryText).lineLimit(1).truncationMode(.middle)
                        Button("显示") { NSWorkspace.shared.activateFileViewerSelecting([registry.fileURL]) }
                        Button("重新读取") { registry.reload() }
                    }
                }
                if let error = registry.lastError { Label(error, om: "exclamationmark.triangle").foregroundStyle(OMColors.warning) }
            }
        }
        .sheet(item: $draft) { item in AgentEditSheet(draft: item) { draft = nil } }
        .sheet(item: $mcpDraft) { item in MCPAgentEditSheet(entry: item) { mcpDraft = nil } }
        .task { path = ProcessInfo.processInfo.environment["PATH"] ?? "" ; registry.reload() }
    }

    // MARK: - 分区

    private var agentsSection: some View {
        Section("Agent") {
            ForEach(registry.data.allAgents) { agent in
                let builtIn = AgentDescriptor.builtIns.contains { $0.id == agent.id }
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(agent.name)
                            if registry.data.resolvedDefault.id == agent.id { OMTag(String(localized: "默认")) }
                            if builtIn { OMTag(String(localized: "内置")) }
                        }
                        if let summary = agent.summary { Note(summary) }
                        if !builtIn, let command = agent.command, GenericACPProvider.resolve(command, path: path) == nil {
                            Label(String(localized: "在 PATH 中找不到 \(command)"), om: "exclamationmark.triangle").font(OMFonts.caption).foregroundStyle(OMColors.warning)
                        }
                    }
                    Spacer()
                    HStack(spacing: 8) {
                        if agent.enabled, registry.data.resolvedDefault.id != agent.id { Button("设为默认") { registry.setDefault(agentId: agent.id) } }
                        if !builtIn {
                            Button("编辑") { draft = AgentDraft(agent) }
                            Button("删除", role: .destructive) { registry.remove(agentId: agent.id) }
                            OMSwitch(String(localized: "启用 \(agent.name)"), isOn: Binding(get: { agent.enabled }, set: { registry.setEnabled($0, agentId: agent.id) }))
                        }
                    }
                    .controlSize(.small)
                }
            }
            HStack {
                Button("添加 ACP Agent…") { draft = AgentDraft() }
                Menu("从预设添加") {
                    ForEach(AgentPreset.all, id: \.id) { preset in Button(preset.name) { draft = AgentDraft(preset, path: path) } }
                }
                .fixedSize()
            }
            Note("任何实现 ACP 的 Agent 都可以加入(命令 + 参数 + 环境变量)。切换 Agent 在窗口工具栏进行,会在当前窗口开始新会话。")
        }
    }

    private var mcpSection: some View {
        Section("Agent 作为工具(Agent-as-MCP)") {
            ForEach(registry.data.mcpAgents) { entry in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.name)
                        Text(([entry.command] + entry.args).joined(separator: " ")).font(OMFonts.monoSmall).foregroundStyle(OMColors.secondaryText)
                    }
                    Spacer()
                    HStack(spacing: 8) {
                        Button("编辑") { mcpDraft = entry }
                        Button("删除", role: .destructive) { registry.removeMCP(id: entry.id) }
                        OMSwitch(String(localized: "启用 \(entry.name)"), isOn: Binding(get: { entry.enabled }, set: { value in var copy = entry; copy.enabled = value; registry.upsertMCP(copy) }))
                    }
                    .controlSize(.small)
                }
            }
            HStack {
                Menu("从预设添加") {
                    ForEach(AgentMCPEntry.presets) { preset in
                        Button(preset.name) { registry.upsertMCP(preset) }.disabled(registry.data.mcpAgents.contains { $0.id == preset.id })
                    }
                }
                .fixedSize()
                Button("添加自定义…") { mcpDraft = AgentMCPEntry(id: "", name: "", command: "") }
            }
            Note("启用后,这些 Agent 会以 stdio MCP 服务器的形式注入新会话,让当前 Agent 把子任务委托给另一个 Agent(例如 `codex mcp-server`)。对新会话生效。")
        }
    }

    private var bridgeSection: some View {
        Section("OhMyAgent Bridge") {
            Toggle("向 Agent 提供 OhMyAgent 工具", isOn: Binding(get: { registry.data.bridge.enabled }, set: { value in registry.update { $0.bridge.enabled = value } }))
            ForEach(BridgeTool.allCases, id: \.rawValue) { tool in
                Toggle(tool.displayName, isOn: Binding(
                    get: { !registry.data.bridge.disabledTools.contains(tool.rawValue) },
                    set: { on in registry.update { value in
                        value.bridge.disabledTools.removeAll { $0 == tool.rawValue }
                        if !on { value.bridge.disabledTools.append(tool.rawValue) }
                    } }
                ))
                .disabled(!registry.data.bridge.enabled)
                .padding(.leading, 16)
            }
            Note("每个会话在应用内置的本机回环端点上注册一个不可猜测的 HTTP MCP 地址(服务器名 `ohmyagent`,无需额外进程),暴露:打开文件、显示改动、读取你在输入框中选中的文字、发送系统通知。会话结束即注销。")
        }
    }
}

/// 自定义 ACP Agent 编辑表单。
struct AgentEditSheet: View {
    @State var draft: AgentDraft
    let close: () -> Void
    @State private var error: String?

    init(draft: AgentDraft, close: @escaping () -> Void) {
        _draft = State(initialValue: draft)
        self.close = close
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(draft.isNew ? String(localized: "添加 ACP Agent") : String(localized: "编辑 Agent")).font(OMFonts.title)
            Form {
                TextField("标识(唯一)", text: $draft.id).disabled(!draft.isNew)
                TextField("名称", text: $draft.name)
                TextField("命令", text: $draft.command, prompt: Text("绝对路径或 PATH 中的命令名"))
                TextField("参数", text: $draft.args, prompt: Text("用空格分隔,如 acp --verbose"))
                TextField("说明", text: $draft.summary)
                VStack(alignment: .leading) {
                    Text("环境变量(每行 KEY=VALUE)").font(OMFonts.small).foregroundStyle(OMColors.secondaryText)
                    TextEditor(text: $draft.env).font(OMFonts.monoSmall).frame(height: 70).settingsEditorStyle()
                }
            }
            .formStyle(.grouped)
            .settingsSurface()
            if let error { Label(error, om: "exclamationmark.triangle").foregroundStyle(OMColors.warning) }
            HStack {
                Spacer()
                Button("取消", action: close).keyboardShortcut(.cancelAction)
                Button("保存") {
                    let existing = AgentRegistryModel.shared.data.agents.first { $0.id == draft.id }
                    if draft.isNew, existing != nil { error = String(localized: "标识已存在"); return }
                    error = AgentRegistryModel.shared.upsert(draft.descriptor(enabled: existing?.enabled ?? true))
                    if error == nil { close() }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

/// Agent-as-MCP 编辑表单。
struct MCPAgentEditSheet: View {
    @State var entry: AgentMCPEntry
    @State private var args: String
    let close: () -> Void
    @State private var error: String?

    init(entry: AgentMCPEntry, close: @escaping () -> Void) {
        _entry = State(initialValue: entry)
        _args = State(initialValue: entry.args.joined(separator: " "))
        self.close = close
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Agent 作为 MCP 工具").font(OMFonts.title)
            Form {
                TextField("标识(唯一)", text: $entry.id)
                TextField("名称", text: $entry.name)
                TextField("命令", text: $entry.command)
                TextField("参数", text: $args, prompt: Text("用空格分隔,如 mcp-server"))
            }
            .formStyle(.grouped)
            .settingsSurface()
            if let error { Label(error, om: "exclamationmark.triangle").foregroundStyle(OMColors.warning) }
            HStack {
                Spacer()
                Button("取消", action: close).keyboardShortcut(.cancelAction)
                Button("保存") {
                    let id = entry.id.trimmingCharacters(in: .whitespaces)
                    guard !id.isEmpty, !entry.command.trimmingCharacters(in: .whitespaces).isEmpty else { error = String(localized: "标识与命令不能为空"); return }
                    entry.id = id
                    entry.name = entry.name.isEmpty ? id : entry.name
                    entry.args = args.split(separator: " ").map(String.init)
                    AgentRegistryModel.shared.upsertMCP(entry)
                    close()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
