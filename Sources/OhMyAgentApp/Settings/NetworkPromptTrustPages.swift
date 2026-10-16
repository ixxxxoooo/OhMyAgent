// @author ygw
// 设置页:网络(代理与超时)、提示词(追加系统提示词、CLAUDE.md)、项目信任。
// 这些选项在新建/恢复会话时注入 Claude 进程,对已运行的会话需重新开始后生效。

import ChatKit
import ClaudeConfigKit
import DesignSystem
import SwiftUI
import WorkbenchKit

/// 网络:代理模式与请求超时。
struct NetworkPage: View {
    @AppStorage(ClientPrefs.Key.proxyMode) private var mode = ProxyMode.system.rawValue
    @AppStorage(ClientPrefs.Key.proxyAddress) private var address = ""
    @AppStorage(ClientPrefs.Key.requestTimeout) private var timeout = 0

    private var proxyMode: ProxyMode { ProxyMode(rawValue: mode) ?? .system }

    var body: some View {
        SettingsForm {
            Section("代理") {
                Picker("代理模式", selection: $mode) {
                    Text("跟随系统").tag(ProxyMode.system.rawValue)
                    Text("直连").tag(ProxyMode.off.rawValue)
                    Text("HTTP 代理").tag(ProxyMode.http.rawValue)
                    Text("SOCKS5 代理").tag(ProxyMode.socks5.rawValue)
                }
                if proxyMode == .http || proxyMode == .socks5 {
                    TextField("代理地址", text: $address, prompt: Text("127.0.0.1:7890"))
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                }
                Note("代理通过环境变量(HTTP_PROXY / HTTPS_PROXY / ALL_PROXY)注入 Claude 进程;「跟随系统」不注入任何变量,「直连」会清空已有代理变量。")
            }
            Section("超时") {
                LabeledContent("请求超时") {
                    HStack {
                        TextField("", value: $timeout, format: .number)
                            .frame(width: 70)
                            .multilineTextAlignment(.trailing)
                        Text("秒(0 = 使用默认值)")
                            .foregroundStyle(OMColors.secondaryText)
                    }
                }
                Note("对应 API_TIMEOUT_MS;网络较慢或模型响应久时可适当调大。")
            }
            Section {
                Note("以上设置对新建或恢复的会话生效,已在运行的会话需要重新开始。")
            }
        }
    }
}

/// 提示词:追加系统提示词与 CLAUDE.md。
struct PromptsPage: View {
    @AppStorage(ClientPrefs.Key.appendPrompt) private var prompt = ""
    @AppStorage(ClientPrefs.Key.loadClaudeMemory) private var loadMemory = true

    var body: some View {
        SettingsForm {
            Section("追加系统提示词") {
                TextEditor(text: $prompt)
                    .font(OMFonts.mono)
                    .frame(minHeight: 140)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(OMColors.card, in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel("追加系统提示词")
                HStack {
                    Text("\(prompt.count) 字").font(OMFonts.caption).foregroundStyle(OMColors.tertiaryText)
                    Spacer()
                    Button("清空") { prompt = "" }.disabled(prompt.isEmpty)
                }
                Note("内容会追加到 Claude Code 默认系统提示词的末尾,适合放置个人偏好、语言要求或团队约定;对所有项目生效。")
            }
            Section("记忆文件") {
                Toggle("加载 CLAUDE.md", isOn: $loadMemory)
                Note("关闭后新会话不再读取用户级与项目级 CLAUDE.md(通过 CLAUDE_CODE_DISABLE_CLAUDE_MDS 实现)。")
            }
            Section {
                Note("以上设置对新建或恢复的会话生效。")
            }
        }
    }
}

/// 项目信任:管理哪些项目已被 Claude Code 信任。
struct ProjectTrustPage: View {
    let workbench: WorkbenchModel
    @State private var statuses: [String: Bool] = [:]
    @State private var errorMessage: String?

    private var projects: [ProjectEntry] { workbench.orderedProjects }

    var body: some View {
        SettingsForm {
            Section("已添加的项目") {
                if projects.isEmpty {
                    Text("还没有项目").foregroundStyle(OMColors.secondaryText)
                }
                ForEach(projects) { project in
                    Toggle(isOn: binding(for: project.id)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(project.name)
                            Text((project.id as NSString).abbreviatingWithTildeInPath)
                                .font(OMFonts.caption)
                                .foregroundStyle(OMColors.secondaryText)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                if let errorMessage {
                    Text(errorMessage).font(OMFonts.caption).foregroundStyle(.red)
                }
            }
            Section {
                Note("信任状态保存在 ~/.claude.json。未信任的项目,Claude Code 在首次打开时会询问是否信任其中的 Hooks、MCP 服务器与环境变量。")
            }
        }
        .task(id: projects.map(\.id)) { reload() }
    }

    /// 读取各项目的信任状态。
    private func reload() {
        statuses = ProjectTrust().statuses(for: projects.map(\.id))
    }

    /// 单个项目的信任开关。
    private func binding(for path: String) -> Binding<Bool> {
        Binding(
            get: { statuses[path] ?? false },
            set: { value in
                do {
                    try ProjectTrust().setTrusted(value, for: path)
                    statuses[path] = value
                    errorMessage = nil
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        )
    }
}
