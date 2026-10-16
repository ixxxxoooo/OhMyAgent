// @author ixxxxoooo
// MCP 服务器管理:列表(作用域/覆盖/启停/审批/健康)、表单与 JSON 添加、Claude Desktop 导入、删除。

import IconKit
import ClaudeConfigKit
import DesignSystem
import SwiftUI

/// MCP 管理页。
struct MCPManagerView: View {
    let center: ConfigCenter
    @State private var selectedID: String?
    @State private var editor: MCPEditorTarget?
    @State private var showJSON = false
    @State private var pendingDelete: MCPServerEntry?

    private var entries: [MCPServerEntry] { center.snapshot.mcp }
    private var selected: MCPServerEntry? { entries.first { $0.id == selectedID } }

    var body: some View {
        ListDetail {
            VStack(spacing: 0) {
                toolbar
                if entries.isEmpty {
                    EmptyHint(icon: "server.rack", title: String(localized: "还没有 MCP 服务器"), message: String(localized: "点击「添加」配置一个,或从 Claude Desktop 导入。"))
                } else {
                    List(entries, selection: $selectedID) { entry in
                        row(entry).tag(entry.id)
                    }
                    .listStyle(.inset)
                }
            }
        } detail: {
            if let entry = selected {
                detail(entry)
            } else {
                EmptyHint(icon: "server.rack", title: String(localized: "选择一个服务器查看详情"))
            }
        }
        .sheet(item: $editor) { target in
            MCPEditorSheet(center: center, target: target) { editor = nil }
        }
        .sheet(isPresented: $showJSON) {
            MCPJSONSheet(center: center) { showJSON = false }
        }
        .confirmationDialog("删除 MCP 服务器?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), presenting: pendingDelete) { entry in
            Button("删除「\(entry.config.name)」", role: .destructive) {
                center.perform(String(localized: "已删除 \(entry.config.name)")) { try MCPStore(paths: center.paths).remove(name: entry.config.name, scope: entry.scope) }
                selectedID = nil
            }
        } message: { entry in
            Text("将从\(entry.scope.displayName)配置中移除,此操作不可撤销。")
        }
    }

    // MARK: - 列表

    private var toolbar: some View {
        HStack(spacing: 8) {
            Menu {
                Button("表单添加…") { editor = MCPEditorTarget(entry: nil) }
                Button("粘贴 JSON 添加…") { showJSON = true }
                Divider()
                Button("从 Claude Desktop 导入") { importFromDesktop() }
            } label: {
                Label("添加", om: "plus")
            }
            .menuStyle(.button)
            Button { Task { await center.checkMCPHealth() } } label: {
                Label("检测连接", om: "waveform.path.ecg")
            }
            .disabled(!center.canRunCLI || center.isBusy)
            .help("运行 claude mcp list 检测各服务器连接状态")
            Spacer()
            Button { center.reload() } label: { Image.om("arrow.clockwise") }
                .help("重新读取配置")
                .accessibilityLabel("刷新")
        }
        .padding(10)
    }

    private func row(_ entry: MCPServerEntry) -> some View {
        HStack(spacing: 8) {
            healthDot(entry)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.config.name).font(OMFonts.body).lineLimit(1)
                HStack(spacing: 4) {
                    Tag(entry.scope.displayName, color: .accentColor)
                    Tag(entry.config.transport.rawValue)
                    if entry.isDisabled { Tag(String(localized: "已禁用"), color: .gray) }
                    if entry.needsApproval { Tag(String(localized: "待批准"), color: OMColors.warning) }
                    if let over = entry.overriddenBy { Tag(String(localized: "被\(over.displayName)覆盖"), color: OMColors.warning) }
                }
            }
            Spacer(minLength: 0)
        }
        .opacity(entry.overriddenBy != nil || entry.isDisabled ? 0.55 : 1)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func healthDot(_ entry: MCPServerEntry) -> some View {
        if let health = center.mcpHealth[entry.config.name] {
            switch health.state {
            case .connected: OMStatusDot(.success)
            case .needsAuth: OMStatusDot(.warning)
            case .failed: OMStatusDot(.failure)
            case .unknown: OMStatusDot(.idle)
            }
        } else {
            OMStatusDot(.idle)
        }
    }

    // MARK: - 详情

    private func detail(_ entry: MCPServerEntry) -> some View {
        let config = entry.config
        let missing = MCPStore.unresolvedVariables(in: config, environment: ProcessInfo.processInfo.environment)
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(config.name).font(OMFonts.title)
                    Tag(entry.scope.displayName, color: .accentColor)
                    Spacer()
                    detailActions(entry)
                }
                if config.transport == .sse {
                    Label("SSE 传输已被 MCP 规范弃用,建议改用 HTTP。", om: "exclamationmark.triangle").font(OMFonts.small).foregroundStyle(OMColors.warning)
                }
                if entry.needsApproval {
                    Label("这是项目 .mcp.json 中的服务器,尚未批准。批准后 Claude 才会启动它。", om: "hand.raised").font(OMFonts.small).foregroundStyle(OMColors.warning)
                }
                if let over = entry.overriddenBy {
                    Label(String(localized: "同名服务器在\(over.displayName)作用域中优先生效,此条目被整体覆盖。"), om: "arrow.triangle.merge").font(OMFonts.small).foregroundStyle(OMColors.warning)
                }
                if let health = center.mcpHealth[config.name] {
                    Label(health.detail, om: "waveform.path.ecg").font(OMFonts.small).foregroundStyle(OMColors.secondaryText)
                }
                if !missing.isEmpty {
                    Label(String(localized: "引用了未设置的环境变量:\(missing.joined(separator: String(localized: "、")))。注意 ANTHROPIC_API_KEY 等凭据变量在远程 url/headers 中会读为空。"), om: "exclamationmark.circle")
                        .font(OMFonts.small).foregroundStyle(OMColors.warning)
                }
                Group {
                    keyValue(String(localized: "传输"), config.transport.displayName)
                    if config.transport == .stdio {
                        keyValue(String(localized: "命令"), ([config.command] + config.args).joined(separator: " "))
                        if !config.env.isEmpty { keyValue(String(localized: "环境变量"), config.env.keys.sorted().map { "\($0)=\(mask(config.env[$0] ?? "", key: $0))" }.joined(separator: "\n")) }
                    } else {
                        keyValue("URL", config.url)
                        if !config.headers.isEmpty { keyValue(String(localized: "请求头"), config.headers.keys.sorted().map { "\($0): \(mask(config.headers[$0] ?? "", key: $0))" }.joined(separator: "\n")) }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func detailActions(_ entry: MCPServerEntry) -> some View {
        HStack(spacing: 8) {
            if entry.needsApproval {
                Button("批准") { center.perform(String(localized: "已批准 \(entry.config.name)")) { try MCPStore(paths: center.paths).approveProjectServer(name: entry.config.name) } }
                    .buttonStyle(.borderedProminent)
            }
            Button(entry.isDisabled ? String(localized: "启用") : String(localized: "禁用")) {
                center.perform(entry.isDisabled ? String(localized: "已启用") : String(localized: "已禁用")) {
                    try MCPStore(paths: center.paths).setEnabled(entry.isDisabled, name: entry.config.name, scope: entry.scope)
                }
            }
            Button("编辑…") { editor = MCPEditorTarget(entry: entry) }
            Button("删除", role: .destructive) { pendingDelete = entry }
        }
    }

    private func keyValue(_ key: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(key).font(OMFonts.caption).foregroundStyle(OMColors.secondaryText)
            Text(value).font(OMFonts.mono).textSelection(.enabled)
        }
    }

    /// 敏感值打码(键名含 key/token/secret/authorization/password)。
    private func mask(_ value: String, key: String) -> String {
        let lower = key.lowercased()
        guard ["key", "token", "secret", "authorization", "password"].contains(where: lower.contains), value.count > 6, !value.contains("${") else { return value }
        return String(value.prefix(4)) + "••••"
    }

    private func importFromDesktop() {
        let servers = MCPStore.claudeDesktopServers(home: center.paths.home)
        guard !servers.isEmpty else {
            center.lastError = String(localized: "没有在 Claude Desktop 配置中找到 MCP 服务器")
            return
        }
        center.perform(String(localized: "已导入 \(servers.count) 个服务器到用户作用域")) {
            let store = MCPStore(paths: center.paths)
            for server in servers { try store.save(server, scope: .user) }
        }
    }
}

/// 编辑目标(entry 为 nil 表示新建)。
struct MCPEditorTarget: Identifiable {
    let id = UUID()
    let entry: MCPServerEntry?
}

/// MCP 表单。
struct MCPEditorSheet: View {
    let center: ConfigCenter
    let target: MCPEditorTarget
    let onClose: () -> Void

    @State private var name = ""
    @State private var scope: ConfigScope = .user
    @State private var transport: MCPTransportKind = .stdio
    @State private var command = ""
    @State private var args = ""
    @State private var env = ""
    @State private var url = ""
    @State private var headers = ""

    private var config: MCPServerConfig {
        MCPServerConfig(name: name, transport: transport, command: command,
                        args: args.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
                        env: parseKeyValues(env, separator: "="), url: url, headers: parseKeyValues(headers, separator: ":"))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(target.entry == nil ? String(localized: "添加 MCP 服务器") : String(localized: "编辑 \(target.entry!.config.name)")).font(OMFonts.title)
            FormRow(label: String(localized: "名称")) { TextField("例如 github", text: $name).textFieldStyle(.roundedBorder) }
            if target.entry == nil {
                FormRow(label: String(localized: "作用域"), hint: String(localized: "用户:所有项目可用;本地:仅此工作区、不入版本库;项目:写入 .mcp.json 与团队共享")) {
                    Picker("", selection: $scope) { ForEach(ConfigScope.allCases) { Text($0.displayName).tag($0) } }
                        .pickerStyle(.segmented).labelsHidden()
                }
            }
            FormRow(label: String(localized: "传输")) {
                Picker("", selection: $transport) { ForEach(MCPTransportKind.allCases) { Text($0.displayName).tag($0) } }.labelsHidden().fixedSize()
            }
            if transport == .stdio {
                FormRow(label: String(localized: "命令")) { TextField("npx", text: $command).textFieldStyle(.roundedBorder).font(OMFonts.mono) }
                FormRow(label: String(localized: "参数"), hint: String(localized: "每行一个参数")) { editor($args) }
                FormRow(label: String(localized: "环境变量"), hint: String(localized: "每行 KEY=VALUE,支持 ${VAR} 与 ${VAR:-默认值}")) { editor($env) }
            } else {
                FormRow(label: "URL") { TextField("https://", text: $url).textFieldStyle(.roundedBorder).font(OMFonts.mono) }
                FormRow(label: String(localized: "请求头"), hint: String(localized: "每行 Key: Value")) { editor($headers) }
            }
            SheetFooter(problems: name.isEmpty && command.isEmpty && url.isEmpty ? [String(localized: "请填写名称与连接信息")] : MCPStore.validate(config),
                        confirmTitle: String(localized: "保存"), onCancel: onClose, onConfirm: save)
        }
        .padding(20)
        .frame(width: 560)
        .onAppear(perform: load)
    }

    private func editor(_ text: Binding<String>) -> some View {
        TextEditor(text: text)
            .font(OMFonts.mono)
            .frame(height: 64)
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(OMColors.hairline))
    }

    private func load() {
        guard let entry = target.entry else { return }
        let c = entry.config
        name = c.name
        scope = entry.scope
        transport = c.transport
        command = c.command
        args = c.args.joined(separator: "\n")
        env = renderKeyValues(c.env, separator: "=")
        url = c.url
        headers = renderKeyValues(c.headers, separator: ": ")
    }

    private func save() {
        let ok = center.perform(String(localized: "已保存 \(name)")) {
            try MCPStore(paths: center.paths).save(config, scope: target.entry?.scope ?? scope, replacing: target.entry?.config.name)
        }
        if ok { onClose() }
    }
}

/// 粘贴 JSON 添加(等价 claude mcp add-json)。
struct MCPJSONSheet: View {
    let center: ConfigCenter
    let onClose: () -> Void
    @State private var name = ""
    @State private var scope: ConfigScope = .user
    @State private var json = "{\n  \"type\": \"http\",\n  \"url\": \"https://example.com/mcp\"\n}"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("通过 JSON 添加").font(OMFonts.title)
            FormRow(label: String(localized: "名称")) { TextField("服务器名称", text: $name).textFieldStyle(.roundedBorder) }
            FormRow(label: String(localized: "作用域")) {
                Picker("", selection: $scope) { ForEach(ConfigScope.allCases) { Text($0.displayName).tag($0) } }.pickerStyle(.segmented).labelsHidden()
            }
            TextEditor(text: $json)
                .font(OMFonts.mono)
                .frame(height: 180)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(OMColors.hairline))
            SheetFooter(problems: name.isEmpty ? [String(localized: "请填写名称")] : [], confirmTitle: String(localized: "添加"), onCancel: onClose) {
                if center.perform(String(localized: "已添加 \(name)"), { try MCPStore(paths: center.paths).addJSON(name: name, json: json, scope: scope) }) { onClose() }
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}
