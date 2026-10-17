// @author ixxxxoooo
// 审批档位设置卡片:终端命令与浏览器访问共用(每次询问 / 允许列表 / 自动运行)。

import AgentHost
import ChatKit
import DesignSystem
import SwiftUI

/// 工具审批卡片:档位 + 允许列表。
struct ToolApprovalCard: View {
    let domain: ToolApprovalDomain
    @AppStorage private var mode: String
    @AppStorage private var listText: String
    @State private var draft = ""

    init(domain: ToolApprovalDomain) {
        self.domain = domain
        _mode = AppStorage(wrappedValue: ToolApprovalMode.ask.rawValue, domain.modeKey)
        _listText = AppStorage(wrappedValue: "", domain.listKey)
    }

    private var entries: [String] { ToolApprovalPolicy.parseList(listText) }

    private var title: String { domain == .terminal ? String(localized: "命令审批") : String(localized: "浏览器审批") }

    private var detail: String {
        domain == .terminal
            ? String(localized: "决定 Agent 运行终端命令前是否询问。含 ; | & > 等串联/重定向的命令永远不会凭允许列表自动放行。")
            : String(localized: "决定 Agent 操作内置浏览器(导航、点击、输入)前是否询问。")
    }

    private var placeholder: String {
        domain == .terminal ? String(localized: "例如 git status 或 npm run *") : String(localized: "例如 localhost 或 *.example.com")
    }

    var body: some View {
        SettingsCard(LocalizedStringKey(title)) {
            SettingsRow("运行方式", detail: detail) {
                OMCompactSegmented(
                    options: ToolApprovalMode.allCases.map { ($0.rawValue, label(for: $0)) },
                    selection: $mode, accessibilityName: title)
            }
            if mode == ToolApprovalMode.auto.rawValue {
                Note(domain == .terminal ? "自动运行时不再询问任何命令,请只在受信任的项目里使用。" : "自动运行时不再询问任何浏览器操作,请只在受信任的项目里使用。")
            }
            if mode == ToolApprovalMode.allowlist.rawValue {
                ForEach(entries, id: \.self) { entry in
                    HStack {
                        Text(verbatim: entry).font(OMFonts.mono).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button { remove(entry) } label: { Image.om("x", size: 12) }
                            .buttonStyle(.omIcon)
                            .omTooltip("移除")
                            .accessibilityLabel(String(localized: "移除 \(entry)"))
                    }
                }
                HStack {
                    TextField("", text: $draft, prompt: Text(verbatim: placeholder)).font(OMFonts.mono).onSubmit(add)
                    Button("添加", action: add).buttonStyle(.omSecondary).disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func label(for mode: ToolApprovalMode) -> String {
        switch mode {
        case .ask: String(localized: "每次询问")
        case .allowlist: String(localized: "允许列表")
        case .auto: String(localized: "自动运行")
        }
    }

    private func add() {
        let value = draft.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return }
        listText = (entries + [value]).joined(separator: "\n")
        draft = ""
    }

    private func remove(_ entry: String) {
        listText = entries.filter { $0 != entry }.joined(separator: "\n")
    }
}

/// Agent 终端的提示符兼容说明:`OHMYAGENT_AGENT` 环境变量与可复制的 Shell 片段。
struct TerminalPromptHintCard: View {
    @State private var shell = "zsh"

    private var snippet: String { shell == "zsh" ? AgentEnvironment.zshSnippet : AgentEnvironment.bashSnippet }

    var body: some View {
        SettingsCard("提示符兼容") {
            Note("Agent 触发的命令会带上环境变量 OHMYAGENT_AGENT=1。Powerlevel10k 等重型提示符主题会让输出错乱,可以在 Shell 配置里检测它并跳过。")
            HStack {
                OMCompactSegmented(options: [("zsh", "zsh"), ("bash", "bash")], selection: $shell, accessibilityName: String(localized: "Shell"))
                Spacer()
                OMCopyButton(help: String(localized: "复制片段")) { snippet }
            }
            Text(verbatim: snippet)
                .font(OMFonts.monoSmall)
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(OMColors.subtleFill, in: RoundedRectangle(cornerRadius: OMRadius.control, style: .continuous))
        }
    }
}
