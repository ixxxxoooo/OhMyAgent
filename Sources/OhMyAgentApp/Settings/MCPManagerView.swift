// @author ixxxxoooo
// MCP 设置页:卡片列表(启用开关、作用域/覆盖/待批准、连接状态)、表单与 JSON 添加、Claude Desktop 导入、删除。
// 参考 Cursor 的「MCP」设置页版式;读写沿用 ClaudeConfigKit 的 `MCPStore`。

import IconKit
import ClaudeConfigKit
import DesignSystem
import SwiftUI

/// MCP 设置页。
struct MCPSettingsPage: View {
    let center: ConfigCenter
    @State private var filter: ConfigScope?
    @State private var expandedID: String?
    @State private var editor: MCPEditorTarget?
    @State private var showJSON = false
    @State private var pendingDelete: MCPServerEntry?

    private var all: [MCPServerEntry] { center.snapshot.mcp }
    private var entries: [MCPServerEntry] { filter.map { scope in all.filter { $0.scope == scope } } ?? all }

    var body: some View {
        ExtensionPage(
            center: center, icon: "server.rack", title: "MCP",
            subtitle: String(localized: "通过 Model Context Protocol 给 Claude 接入外部工具与数据源。配置写入 ~/.claude.json 或项目的 .mcp.json。"),
            errorKey: "MCP"
        ) {
            Button { Task { await center.checkMCPHealth() } } label: {
                // 原位替换:检测中图标换成转圈、文字换成「检测中…」,按钮宽度保持不变,页面不会被挤动
                HStack(spacing: 6) {
                    if center.isCheckingMCP {
                        ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 14, height: 14)
                        Text("检测中…")
                    } else {
                        Image.om("waveform.path.ecg", size: 14)
                        Text("检测连接")
                    }
                }
                .frame(minWidth: 84)
            }
                .disabled(!center.canRunCLI || center.isBusy || center.isCheckingMCP)
                .help("运行 claude mcp list 检测各服务器连接状态")
            Button { center.reload() } label: { Image.om("arrow.clockwise") }
                .help("重新读取配置")
                .accessibilityLabel("刷新")
            Menu {
                Button("表单添加…") { editor = MCPEditorTarget(entry: nil) }
                Button("粘贴 JSON 添加…") { showJSON = true }
                Divider()
                Button("从 Claude Desktop 导入") { importFromDesktop() }
            } label: {
                Label("添加服务器", om: "plus")
            }
            .menuStyle(.button)
            .buttonStyle(.borderedProminent)
        } content: {
            if !all.isEmpty { scopeFilter }
            if entries.isEmpty {
                ExtensionEmptyCard(
                    icon: "server.rack",
                    title: all.isEmpty ? String(localized: "还没有 MCP 服务器") : String(localized: "这个范围内没有服务器"),
                    message: String(localized: "点击右上角「添加服务器」配置一个,或从 Claude Desktop 导入。")
                )
            } else {
                ExtensionCardList {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 { ExtensionRowDivider() }
                        row(entry)
                    }
                }
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
                expandedID = nil
            }
        } message: { entry in
            Text("将从\(entry.scope.displayName)配置中移除,此操作不可撤销。")
        }
    }

    // MARK: - 过滤

    private var scopeFilter: some View {
        Picker("", selection: $filter) {
            Text("全部 \(all.count)").tag(ConfigScope?.none)
            ForEach(ConfigScope.allCases) { scope in
                let count = all.filter { $0.scope == scope }.count
                Text(count > 0 ? "\(scope.displayName) \(count)" : scope.displayName).tag(ConfigScope?.some(scope))
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 360)
    }

    // MARK: - 行

    private func row(_ entry: MCPServerEntry) -> some View {
        let config = entry.config
        let dimmed = entry.overriddenBy != nil || entry.isDisabled
        return ExtensionRow(
            icon: "server.rack", tint: tint(entry), title: config.name,
            subtitle: summary(of: config), monoSubtitle: true, dimmed: dimmed,
            expanded: expandedID == entry.id,
            onTap: { omWithAnimation { expandedID = expandedID == entry.id ? nil : entry.id } },
            badges: {
                Tag(entry.scope.displayName, color: OMColors.accent2)
                Tag(config.transport.rawValue)
                if entry.needsApproval { Tag(String(localized: "待批准"), color: OMColors.warning) }
                if let over = entry.overriddenBy { Tag(String(localized: "被\(over.displayName)覆盖"), color: OMColors.warning) }
            },
            trailing: { trailing(entry) },
            detail: { detail(entry) }
        )
    }

    /// 行右侧:连接状态 + 启用开关(待批准时换成「批准」按钮)+ 更多菜单。
    private func trailing(_ entry: MCPServerEntry) -> some View {
        HStack(spacing: 10) {
            healthLabel(entry)
            if entry.needsApproval {
                Button("批准") { center.perform(String(localized: "已批准 \(entry.config.name)")) { try MCPStore(paths: center.paths).approveProjectServer(name: entry.config.name) } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            } else {
                Toggle("", isOn: Binding(
                    get: { !entry.isDisabled },
                    set: { enabled in
                        center.perform(enabled ? String(localized: "已启用") : String(localized: "已禁用")) {
                            try MCPStore(paths: center.paths).setEnabled(enabled, name: entry.config.name, scope: entry.scope)
                        }
                    }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .accessibilityLabel(String(localized: "启用 \(entry.config.name)"))
            }
            Menu {
                Button("编辑…") { editor = MCPEditorTarget(entry: entry) }
                Divider()
                Button("删除…", role: .destructive) { pendingDelete = entry }
            } label: {
                Image.om("ellipsis", size: 14).frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("更多操作")
        }
    }

    @ViewBuilder
    private func healthLabel(_ entry: MCPServerEntry) -> some View {
        if center.isCheckingMCP {
            ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 14, height: 14)
        } else if let health = center.mcpHealth[entry.config.name] {
            HStack(spacing: 5) {
                healthDot(health)
                Text(verbatim: healthText(health)).font(OMFonts.caption).foregroundStyle(OMColors.secondaryText)
            }
            .help(health.detail)
        }
    }

    @ViewBuilder
    private func healthDot(_ health: MCPHealthStatus) -> some View {
        switch health.state {
        case .connected: OMStatusDot(.success)
        case .needsAuth: OMStatusDot(.warning)
        case .failed: OMStatusDot(.failure)
        case .unknown: OMStatusDot(.idle)
        }
    }

    private func healthText(_ health: MCPHealthStatus) -> String {
        switch health.state {
        case .connected: return String(localized: "已连接")
        case .needsAuth: return String(localized: "需要认证")
        case .failed: return String(localized: "连接失败")
        case .unknown: return String(localized: "未知")
        }
    }

    /// 图标瓦片的色调:按连接状态着色,未检测时用强调色。
    private func tint(_ entry: MCPServerEntry) -> Color {
        guard let health = center.mcpHealth[entry.config.name] else { return OMColors.accent }
        switch health.state {
        case .connected: return .green
        case .needsAuth: return OMColors.warning
        case .failed: return .red
        case .unknown: return OMColors.accent
        }
    }

    /// 单行摘要:命令或 URL。
    private func summary(of config: MCPServerConfig) -> String {
        config.transport == .stdio ? ([config.command] + config.args).joined(separator: " ") : config.url
    }

    // MARK: - 展开详情

    private func detail(_ entry: MCPServerEntry) -> some View {
        let config = entry.config
        let missing = MCPStore.unresolvedVariables(in: config, environment: ProcessInfo.processInfo.environment)
        return VStack(alignment: .leading, spacing: 10) {
            if config.transport == .sse {
                warning("SSE 传输已被 MCP 规范弃用,建议改用 HTTP。", icon: "exclamationmark.triangle")
            }
            if entry.needsApproval {
                warning("这是项目 .mcp.json 中的服务器,尚未批准。批准后 Claude 才会启动它。", icon: "hand.raised")
            }
            if let over = entry.overriddenBy {
                warning(String(localized: "同名服务器在\(over.displayName)作用域中优先生效,此条目被整体覆盖。"), icon: "arrow.triangle.merge")
            }
            if let health = center.mcpHealth[config.name] {
                Label(health.detail, om: "waveform.path.ecg").font(OMFonts.small).foregroundStyle(OMColors.secondaryText)
            }
            if !missing.isEmpty {
                warning(String(localized: "引用了未设置的环境变量:\(missing.joined(separator: String(localized: "、")))。注意 ANTHROPIC_API_KEY 等凭据变量在远程 url/headers 中会读为空。"), icon: "exclamationmark.circle")
            }
            keyValue(String(localized: "传输"), config.transport.displayName)
            if config.transport == .stdio {
                keyValue(String(localized: "命令"), ([config.command] + config.args).joined(separator: " "))
                if !config.env.isEmpty { keyValue(String(localized: "环境变量"), config.env.keys.sorted().map { "\($0)=\(mask(config.env[$0] ?? "", key: $0))" }.joined(separator: "\n")) }
            } else {
                keyValue("URL", config.url)
                if !config.headers.isEmpty { keyValue(String(localized: "请求头"), config.headers.keys.sorted().map { "\($0): \(mask(config.headers[$0] ?? "", key: $0))" }.joined(separator: "\n")) }
            }
            HStack(spacing: 8) {
                Button("编辑…") { editor = MCPEditorTarget(entry: entry) }
                Button("删除…", role: .destructive) { pendingDelete = entry }
            }
            .controlSize(.small)
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func warning(_ text: String, icon: String) -> some View {
        Label(text, om: icon).font(OMFonts.small).foregroundStyle(OMColors.warning)
    }

    private func keyValue(_ key: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(key).font(OMFonts.caption).foregroundStyle(OMColors.secondaryText)
            Text(value).font(OMFonts.monoSmall).textSelection(.enabled)
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
            .settingsEditorStyle()
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
                .settingsEditorStyle()
            SheetFooter(problems: name.isEmpty ? [String(localized: "请填写名称")] : [], confirmTitle: String(localized: "添加"), onCancel: onClose) {
                if center.perform(String(localized: "已添加 \(name)"), { try MCPStore(paths: center.paths).addJSON(name: name, json: json, scope: scope) }) { onClose() }
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}
