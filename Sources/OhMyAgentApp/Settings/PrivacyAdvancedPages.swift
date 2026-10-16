// @author ixxxxoooo
// 设置页:隐私、高级(路径覆盖、环境变量、MCP 运行参数、客户端能力、数据管理)。

import AgentHost
import AppKit
import ChatKit
import ClaudeConfigKit
import DesignSystem
import SwiftUI

/// 隐私。
struct PrivacyPage: View {
    @Bindable var model: ClaudeSettingsModel
    @AppStorage(ClientPrefs.Key.redactLogs) private var redactLogs = true

    var body: some View {
        SettingsForm {
            Section { ScopeHeader(model: model) }
            Section("数据上报") {
                Toggle("关闭遥测(DISABLE_TELEMETRY)", isOn: flag("DISABLE_TELEMETRY"))
                Toggle("关闭错误上报(DISABLE_ERROR_REPORTING)", isOn: flag("DISABLE_ERROR_REPORTING"))
                Toggle("关闭非必要网络流量(DISABLE_NONESSENTIAL_TRAFFIC)", isOn: flag("CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"))
                Note("以上开关写入 settings.json 的 env,对新建会话生效。OhMyAgent 自身不包含任何遥测。")
            }
            Section("本地日志") {
                Toggle("导出诊断时脱敏(路径与令牌)", isOn: $redactLogs)
                Note("脱敏会把用户目录替换为 ~,并抹去形如 sk-… / Bearer … 的字符串。")
            }
            Section("凭据") {
                Note("OhMyAgent 不读取 Keychain 中的令牌,也不保存任何账号信息;登录与凭据完全由官方 claude 管理。")
            }
        }
    }

    private func flag(_ name: String) -> Binding<Bool> {
        let binding = model.envBinding(name)
        return Binding(get: { binding.wrappedValue == "1" }, set: { binding.wrappedValue = $0 ? "1" : "" })
    }
}

/// 高级。
struct AdvancedPage: View {
    @Bindable var model: ClaudeSettingsModel
    @AppStorage(ClientPrefs.Key.pathNode) private var nodePath = ""
    @AppStorage(ClientPrefs.Key.pathClaude) private var claudePath = ""
    @AppStorage(ClientPrefs.Key.pathAdapter) private var adapterPath = ""
    @AppStorage(ClientPrefs.Key.featureFileSystem) private var fileSystem = false
    @AppStorage(ClientPrefs.Key.featureTerminal) private var terminal = false
    @AppStorage(ClientPrefs.Key.featureElicitation) private var elicitation = true
    @AppStorage(ClientPrefs.Key.mcpToolSearch) private var mcpToolSearch = McpToolSearch.auto.rawValue
    @State private var tools: LocatedTools?
    @State private var envText = ""
    @State private var envDirty = false
    @State private var backupCount = 0
    @State private var notice: String?

    var body: some View {
        SettingsForm {
            Section("工具路径(留空自动探测)") {
                TextField("node", text: $nodePath, prompt: Text(tools?.nodePath ?? String(localized: "未找到")))
                TextField("claude", text: $claudePath, prompt: Text(tools?.claudePath ?? String(localized: "未找到")))
                TextField("ACP 适配器入口", text: $adapterPath, prompt: Text(tools?.adapterEntry ?? String(localized: "未找到")))
                HStack {
                    Button("应用并重新探测") { Task { await redetect() } }
                    if let version = tools?.nodeVersion { Text("node \(version)").font(OMFonts.small).foregroundStyle(OMColors.secondaryText) }
                }
                Note("修改后对新建会话生效;已打开的会话保持原有进程。")
            }
            Section("上下文优化") {
                Picker("MCP 工具按需加载", selection: $mcpToolSearch) {
                    ForEach(McpToolSearch.allCases) { mode in Text(mode.displayName).tag(mode.rawValue) }
                }
                Note("开启后 MCP 工具定义不再启动即全部载入上下文,而是由模型按需搜索加载,MCP 较多时能明显降低初始占用。「自动」沿用 Claude Code 默认:直连官方 API 且 MCP 工具超过窗口 10% 时才启用。")
                if mcpToolSearch == McpToolSearch.on.rawValue {
                    Label("经第三方网关或模型映射使用时,网关必须支持 tool_reference 内容块,否则请求可能报错;遇到问题请改回「自动」。", om: "triangle-alert")
                        .font(OMFonts.caption).foregroundStyle(OMColors.warning)
                }
                Note("对新建或恢复的会话生效。对应环境变量 ENABLE_TOOL_SEARCH。")
            }
            Section("MCP 运行参数") {
                ScopeHeader(model: model)
                envField(String(localized: "启动超时(ms)"), "MCP_TIMEOUT")
                envField(String(localized: "工具调用超时(ms)"), "MCP_TOOL_TIMEOUT")
                envField(String(localized: "输出 token 上限"), "MAX_MCP_OUTPUT_TOKENS")
            }
            Section("环境变量(\(model.scope.displayName)层)") {
                TextEditor(text: $envText)
                    .font(OMFonts.monoSmall)
                    .frame(minHeight: 110)
                    .settingsEditorStyle()
                    .onChange(of: envText) { envDirty = true }
                HStack {
                    Button("保存") { saveEnv() }.disabled(!envDirty)
                    Button("还原") { loadEnv() }.disabled(!envDirty)
                    Text("每行 KEY=VALUE").font(OMFonts.small).foregroundStyle(OMColors.secondaryText)
                }
            }
            Section("客户端能力(新会话生效)") {
                Toggle("由 OhMyAgent 代理文件读写(fs/*,默认关闭)", isOn: $fileSystem)
                Toggle("由 OhMyAgent 提供内联终端(terminal/*,默认关闭)", isOn: $terminal)
                Toggle("允许 Agent 向我提问(elicitation)", isOn: $elicitation)
                Note("未开启的能力不会在 ACP initialize 中声明,Agent 使用自身实现。")
            }
            Section("数据管理") {
                LabeledContent("应用数据目录") {
                    Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([Self.supportDirectory]) }
                }
                LabeledContent("配置备份(.oma-backup)") {
                    HStack { Text("\(backupCount) 个"); Button("清理") { cleanBackups() }.disabled(backupCount == 0) }
                }
                LabeledContent("客户端偏好") {
                    Button("恢复默认", role: .destructive) { ClientPrefs.resetAll(); notice = String(localized: "已恢复客户端默认偏好(不影响 Claude 配置)") }
                }
                if let notice { Note(notice) }
            }
        }
        .task { tools = await Toolchain.shared.resolve(); loadEnv(); countBackups() }
        .onChange(of: model.scope) { loadEnv() }
    }

    static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("OhMyAgent", isDirectory: true)
    }

    private func envField(_ title: String, _ name: String) -> some View {
        LabeledContent(title) {
            TextField("", text: model.envBinding(name), prompt: Text("默认")).frame(width: 120).multilineTextAlignment(.trailing)
        }
    }

    private func redetect() async {
        await Toolchain.shared.setOverrides(ClientPrefs.pathOverrides())
        tools = await Toolchain.shared.resolve()
    }

    private func loadEnv() {
        envText = model.dictionary(["env"]).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
        envDirty = false
    }

    private func saveEnv() {
        var env: [String: String] = [:]
        for line in envText.split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, !text.hasPrefix("#"), let index = text.firstIndex(of: "=") else { continue }
            let key = String(text[..<index]).trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { env[key] = String(text[text.index(after: index)...]) }
        }
        model.set(["env"], env.isEmpty ? nil : env)
        loadEnv()
    }

    private func backupFiles() -> [URL] {
        let candidates = [model.paths.claudeDirectory] + (model.paths.workspace.map { [$0.appendingPathComponent(".claude")] } ?? [])
        return candidates.flatMap { directory -> [URL] in
            let items = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            return items.filter { $0.lastPathComponent.hasSuffix(".oma-backup") }
        }
    }

    private func countBackups() { backupCount = backupFiles().count }

    private func cleanBackups() {
        let files = backupFiles()
        for file in files { try? FileManager.default.removeItem(at: file) }
        notice = String(localized: "已清理 \(files.count) 个备份")
        countBackups()
    }
}
