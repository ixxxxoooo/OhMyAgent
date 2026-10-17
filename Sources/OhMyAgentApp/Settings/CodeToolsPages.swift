// @author ixxxxoooo
// 设置页「源代码管理」「代码智能」:Cursor 风格的分组卡片。

import ChatKit
import DesignSystem
import SwiftUI

/// 源代码管理:提交署名与 AI 提交说明。
struct SourceControlPage: View {
    @AppStorage(ClientPrefs.Key.scmCoAuthor) private var coAuthor = false
    @AppStorage(ClientPrefs.Key.scmAICommitMessage) private var aiMessage = true
    @AppStorage(ClientPrefs.Key.worktreeMaxCount) private var worktreeMax = 25
    @AppStorage(ClientPrefs.Key.worktreeCleanupHours) private var worktreeHours = 6

    var body: some View {
        SettingsScroll {
            SettingsCard("提交") {
                SettingsToggleRow(
                    "AI 生成提交说明",
                    detail: "在源代码管理面板的提交框旁显示 ✦ 按钮,根据改动与最近提交风格生成说明。",
                    isOn: $aiMessage
                )
                SettingsToggleRow(
                    "提交时署名 OhMyAgent",
                    detail: "在提交说明末尾追加 Co-authored-by 尾注,方便在 Git 历史里区分由 Agent 参与的提交。默认关闭。",
                    isOn: $coAuthor
                )
                Note("署名只在通过 OhMyAgent 提交时追加,不会修改你的 git 配置;已包含同一署名时不会重复追加。").footnote()
            }
            SettingsCard("工作树") {
                SettingsNumericField(title: "数量上限", value: $worktreeMax, format: IntegerFormatStyle<Int>(), unit: "个")
                SettingsNumericField(title: "检查间隔", value: $worktreeHours, format: IntegerFormatStyle<Int>(), unit: "小时")
                Note("`/worktree` 与「在工作树中运行」会在 ~/.ohmyagent/worktrees 下创建隔离检出。超过数量上限时,会询问是否清理最旧且没有未提交改动的工作树,不会静默删除。初始化脚本放在项目的 .oma/worktrees.json(也兼容 .cursor/worktrees.json),键 setup-worktree 为命令数组或脚本路径,运行时可用环境变量 ROOT_WORKTREE_PATH 取得主检出路径。").footnote()
            }
        }
    }
}

/// 代码智能:语言服务器与索引忽略。
struct CodeIntelligencePage: View {
    @AppStorage(ClientPrefs.Key.editorLSP) private var lspEnabled = true
    @AppStorage(ClientPrefs.Key.lspMaxWorkspaces) private var maxWorkspaces = 4
    @AppStorage(ClientPrefs.Key.indexIgnoreGlobs) private var ignoreGlobs = ""

    /// 上限档位 1…8。
    private var limit: Int { min(max(maxWorkspaces == 0 ? 4 : maxWorkspaces, 1), 8) }

    var body: some View {
        SettingsScroll {
            SettingsCard("语言服务器(LSP)") {
                SettingsToggleRow("启用诊断、悬停提示、跳转定义与补全", isOn: $lspEnabled)
                SettingsSliderRow(
                    title: String(localized: "同时保留的工作区"),
                    valueText: String(localized: "\(limit) 个"),
                    stops: (1...8).map { "\($0)" },
                    index: Binding(get: { limit - 1 }, set: { maxWorkspaces = min(max($0, 0), 7) + 1 })
                )
                Note("超过上限时,会回收最久未用且没有打开文件的语言服务器,降低内存占用。").footnote()
                Note("Swift 使用 Xcode 自带的 sourcekit-lsp;TypeScript/JavaScript 需要 typescript-language-server,Python 需要 pyright(npm i -g typescript-language-server typescript pyright)。悬停停留查看类型,⌘ 点击或 F12 跳转定义,⌃Space 补全,输入 . 自动补全。").footnote()
            }
            SettingsCard("忽略文件") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("索引忽略规则").font(OMFonts.body)
                    TextEditor(text: $ignoreGlobs)
                        .font(OMFonts.mono)
                        .scrollContentBackground(.hidden)
                        .frame(height: 96)
                        .padding(6)
                        .background(OMColors.subtleFill, in: RoundedRectangle(cornerRadius: OMRadius.control, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: OMRadius.control, style: .continuous).strokeBorder(OMColors.hairline, lineWidth: 0.5))
                        .accessibilityLabel("索引忽略规则")
                }
                Note("每行一个 glob,例如 *.min.js、docs/generated/、**/fixtures。匹配的文件不会出现在 ⌘K 文件搜索、@ 补全与全局搜索里;新打开的项目或重新索引后生效。").footnote()
            }
        }
    }
}
