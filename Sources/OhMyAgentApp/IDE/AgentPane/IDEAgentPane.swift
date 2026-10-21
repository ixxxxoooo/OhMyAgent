// @author ixxxxoooo
// IDE 窗口右侧的 Agent 面板:嵌入与 Agents Window 同一套对话界面(`ChatView`),
// 会话使用本窗口专属的槽位(不与 Agents Window 的会话标签冲突);文件引用在本窗口的编辑器里打开。

import ChatKit
import DesignSystem
import IconKit
import IDEKit
import OMLog
import SwiftUI
import WorkbenchKit

struct IDEAgentPane: View {
    let workspace: IDEWorkspace
    private let appearance = AppearanceModel.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(OMColors.hairline).frame(height: 1)
            content
        }
        .frame(maxHeight: .infinity)
        .background(OMColors.surface)
    }

    private var header: some View {
        HStack(spacing: 4) {
            Text("Agent").font(OMFonts.small).foregroundStyle(OMColors.secondaryText)
            Spacer(minLength: 0)
            iconButton("plus", String(localized: "新对话")) { workspace.newAgentConversation() }
            iconButton("external-link", String(localized: "到 Agents Window 对话")) { IDEWindowManager.shared.switchToAgent() }
            iconButton("x", String(localized: "关闭")) { workspace.model.toggleAgentPane() }
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
    }

    @ViewBuilder
    private var content: some View {
        if workspace.root == nil {
            OMEmptyState { Label("Agent 面板", om: "sparkles") } description: { Text("打开文件夹后即可在这里与 Agent 对话") }
        } else if let session = workspace.agentSession {
            ChatView(model: session)
                .id(appearance.renderKey)
                .environment(session)
        } else {
            OMSpinner(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                .task(id: workspace.root) { workspace.prepareAgentSession() }
        }
    }

    private func iconButton(_ icon: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image.om(icon, size: 14) }
            .buttonStyle(.omIcon)
            .omTooltip(title)
            .accessibilityLabel(title)
    }
}

extension IDEWorkspace {
    /// 本窗口 Agent 面板使用的会话(未创建为 nil)。
    var agentSession: SessionModel? {
        guard let projectID = agentProjectID else { return nil }
        return AppEnvironment.shared.workbench.conversations[ConversationKey(projectID: projectID, slot: agentSlot)]
    }

    /// 确保工作区在工作台里登记为项目(不改变 Agents Window 当前选中的项目),并创建本窗口的会话。
    func prepareAgentSession() {
        guard let root, FileManager.default.fileExists(atPath: root) else { return }
        let workbench = AppEnvironment.shared.workbench
        let projectID: String
        if let existing = workbench.projects.first(where: { IDEMetrics.normalizedRoot($0.id) == root }) {
            projectID = existing.id
        } else {
            let previous = workbench.selectedProjectID
            guard let created = workbench.openProject(URL(fileURLWithPath: root)) else { return }
            projectID = created
            // 登记项目会顺带选中它;Agents Window 的当前项目保持不变
            if let previous, previous != created { workbench.select(project: previous) }
        }
        agentProjectID = projectID
        let started = ContinuousClock.now
        workbench.ensureSession(project: projectID, slot: agentSlot)
        Log.ui.info("IDE Agent 面板会话就绪", ["project": (projectID as NSString).lastPathComponent, "slot": agentSlot ?? "-", "ms": "\(Int((ContinuousClock.now - started).seconds * 1000))"])
    }

    /// 开始一个新对话(新的槽位)。
    func newAgentConversation() {
        agentSlot = "ide-" + UUID().uuidString.prefix(8).lowercased()
        prepareAgentSession()
    }

    /// 把文件(或选区)作为 `@引用` 追加到 Agent 面板的输入框,并显示面板。
    /// - Parameter token: 引用标记(如 `@Sources/A.swift:12-20`)
    func addReferenceToChat(_ token: String) {
        model.agentPaneVisible = true
        if agentSession == nil { prepareAgentSession() }
        guard let session = agentSession else { return }
        session.draft = EditorReference.appending(token, to: session.draft)
    }

    /// 把当前编辑器文件作为引用加入对话。
    func addActiveFileToChat() {
        guard let path = model.activeFilePath, let root else { return }
        let display = path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : path
        addReferenceToChat("@" + display)
    }
}
