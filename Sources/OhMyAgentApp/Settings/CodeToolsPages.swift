// @author ixxxxoooo
// 设置页「源代码管理」「代码智能」:Cursor 风格的分组卡片。

import ChatKit
import DesignSystem
import SwiftUI

/// 源代码管理:提交署名与 AI 提交说明。
struct SourceControlPage: View {
    @AppStorage(ClientPrefs.Key.scmCoAuthor) private var coAuthor = false
    @AppStorage(ClientPrefs.Key.scmCollaborators) private var collaboratorsJSON = ""
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
            SettingsCard("协作者") {
                ForEach(collaborators) { item in
                    CollaboratorRow(item: item, update: update, remove: remove)
                }
                HStack {
                    Button { add() } label: { Label("添加协作者", om: "plus") }
                        .buttonStyle(.omSecondary)
                        .accessibilityLabel("添加协作者")
                    Spacer()
                }
                Note("名单里的协作者会在提交说明末尾追加 Co-authored-by 尾注。在源代码管理面板提交时自动追加;智能体自己执行 git commit 时也会被要求带上(对新建的会话生效)。名字和邮箱都填写完整、邮箱格式正确才会生效。").footnote()
            }
            SettingsCard("工作树") {
                SettingsNumericField(title: "数量上限", value: $worktreeMax, format: IntegerFormatStyle<Int>(), unit: "个")
                SettingsNumericField(title: "检查间隔", value: $worktreeHours, format: IntegerFormatStyle<Int>(), unit: "小时")
                Note("`/worktree` 与「在工作树中运行」会在 ~/.ohmyagent/worktrees 下创建隔离检出。超过数量上限时,会询问是否清理最旧且没有未提交改动的工作树,不会静默删除。初始化脚本放在项目的 .oma/worktrees.json(也兼容 .cursor/worktrees.json),键 setup-worktree 为命令数组或脚本路径,运行时可用环境变量 ROOT_WORKTREE_PATH 取得主检出路径。").footnote()
            }
        }
    }
}

extension SourceControlPage {
    /// 当前名单(来自偏好)。
    fileprivate var collaborators: [CommitCollaborator] { CommitCollaborator.decode(collaboratorsJSON) }

    /// 新增一个空白协作者,等待用户填写。
    fileprivate func add() {
        collaboratorsJSON = CommitCollaborator.encode(collaborators + [CommitCollaborator()])
    }

    /// 保存某位协作者的修改。
    fileprivate func update(_ item: CommitCollaborator) {
        var list = collaborators
        guard let index = list.firstIndex(where: { $0.id == item.id }), list[index] != item else { return }
        list[index] = item
        collaboratorsJSON = CommitCollaborator.encode(list)
    }

    /// 删除某位协作者。
    fileprivate func remove(_ item: CommitCollaborator) {
        collaboratorsJSON = CommitCollaborator.encode(collaborators.filter { $0.id != item.id })
    }
}

/// 协作者的一行:姓名、邮箱与删除按钮;填写不完整时用警告色提示该行暂不生效。
private struct CollaboratorRow: View {
    let item: CommitCollaborator
    let update: (CommitCollaborator) -> Void
    let remove: (CommitCollaborator) -> Void
    @State private var draft: CommitCollaborator

    init(item: CommitCollaborator, update: @escaping (CommitCollaborator) -> Void, remove: @escaping (CommitCollaborator) -> Void) {
        self.item = item
        self.update = update
        self.remove = remove
        _draft = State(initialValue: item)
    }

    var body: some View {
        HStack(spacing: OMSpacing.sm) {
            TextField("", text: $draft.name, prompt: Text("姓名"))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("协作者姓名")
            TextField("", text: $draft.email, prompt: Text("邮箱"))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("协作者邮箱")
            Image.om(draft.isValid ? "check" : "circle-alert", size: 12)
                .foregroundStyle(draft.isValid ? OMColors.success : OMColors.warning)
                .omTooltip(draft.isValid ? "有效" : "名字与邮箱需填写完整,否则不会追加")
                .accessibilityLabel(draft.isValid ? "有效" : "未填写完整")
            Button { remove(item) } label: {
                Image.om("trash", size: 13).foregroundStyle(OMColors.tertiaryText).frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .omTooltip("删除")
            .accessibilityLabel("删除协作者")
        }
        .onChange(of: draft) { _, value in update(value) }
    }
}

/// 代码智能:语言服务器与索引忽略。
struct CodeIntelligencePage: View {
    @AppStorage(ClientPrefs.Key.editorLSP) private var lspEnabled = true
    @AppStorage(ClientPrefs.Key.lspMaxWorkspaces) private var maxWorkspaces = 4
    @AppStorage(ClientPrefs.Key.indexIgnoreGlobs) private var ignoreGlobs = ""
    @AppStorage(ClientPrefs.Key.indexUseGitignore) private var useGitignore = true

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
                SettingsToggleRow("索引时跳过 .gitignore 列出的文件", isOn: $useGitignore)
                Note("读取项目根目录的 .gitignore(不支持 ! 取反规则与子目录里的 .gitignore)。关闭后 ⌘K / ⌘P 文件搜索会包含这些文件;新打开的项目或重新索引后生效。").footnote()
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
