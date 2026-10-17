// @author ixxxxoooo
// 源代码管理面板:分支、同步、提交框、冲突/已暂存/更改/未跟踪分组;点击文件打开 Diff 标签。

import AppKit
import DesignSystem
import GitKit
import IconKit
import SwiftUI
import WorkbenchKit

/// 右栏「Git」页:分支/同步、提交框、本轮 Agent 改动、更改分组、提交图谱。
struct SCMView: View {
    let workbench: WorkbenchModel

    var body: some View {
        if let project = workbench.selectedProject {
            SCMContent(workbench: workbench, model: GitStore.shared.model(for: project.id))
                .id(project.id)
        } else {
            OMEmptyState { Label("没有项目", om: "folder", size: 28) } description: { Text("添加一个项目后,这里会显示它的 Git 状态。") }
        }
    }
}

private struct SCMContent: View {
    let workbench: WorkbenchModel
    @Bindable var model: GitModel
    @State private var branchShown = false

    var body: some View {
        VStack(spacing: 0) {
            switch model.phase {
            case .unknown:
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            case .notRepository:
                notRepository
            case .ready:
                header
                Divider()
                commitBox
                Divider()
                changeList
            }
            if let error = model.lastError { errorBanner(error) }
        }
        .task {
            // 面板可见期间轮询(状态不变时逐步退避,大仓库按单次耗时放慢);操作完成后另有即时刷新
            var delay = 3.0
            while !Task.isCancelled {
                let before = model.status
                let started = ContinuousClock.now
                await model.refresh(full: model.branches.isEmpty)
                let took = (ContinuousClock.now - started).seconds
                delay = PollBackoff.next(previous: delay, changed: model.status != before, duration: took)
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }

    // MARK: 头部

    private var header: some View {
        HStack(spacing: 6) {
            branchMenu
            Spacer(minLength: 0)
            if let busy = model.busy {
                ProgressView().controlSize(.mini)
                Text(LocalizedStringKey(busy)).font(OMFonts.caption).foregroundStyle(OMColors.secondaryText)
            }
            syncButton(icon: "arrow-down", count: model.status.behind, help: "拉取") { Task { await model.pull() } }
            syncButton(icon: "arrow-up", count: model.status.ahead, help: "推送") { Task { await model.push() } }
            moreMenu
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    private var branchEntries: [PickEntry] {
        let locals = model.branches.filter { !$0.isRemote }
        let remotes = model.branches.filter { $0.isRemote && !$0.name.hasSuffix("/HEAD") }
        var result = locals.map { PickEntry(id: "local:\($0.name)", title: $0.name, icon: "git-branch") }
        result += remotes.map { PickEntry(id: "remote:\($0.name)", title: $0.name, group: String(localized: "远程分支"), icon: "git-branch") }
        result.append(PickEntry(id: "__create__", title: String(localized: "新建分支…"), group: String(localized: "更多"), icon: "plus"))
        return result
    }

    private var branchMenu: some View {
        Button { branchShown.toggle() } label: {
            HStack(spacing: 4) {
                Image.om("git-branch", size: 12)
                Text(branchTitle).font(OMFonts.small.weight(.semibold)).lineLimit(1)
                Image.om("chevron-down", size: 10).foregroundStyle(OMColors.tertiaryText)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel("切换分支")
        .omPicker(isPresented: $branchShown, entries: branchEntries, selectedID: model.status.branch.map { "local:\($0)" },
                  placeholder: String(localized: "搜索分支"), placement: .below, width: 260, showsSearch: true) { entry in
            if entry.id == "__create__" {
                if let name = GitDialogs.prompt(title: String(localized: "新建分支"), message: String(localized: "基于当前提交创建并切换到新分支。"), placeholder: "feature/xxx", confirm: String(localized: "创建")) {
                    Task { await model.createBranch(name) }
                }
            } else if entry.id.hasPrefix("local:") {
                let name = String(entry.id.dropFirst(6))
                if name != model.status.branch { Task { await model.checkout(name) } }
            } else if entry.id.hasPrefix("remote:") {
                // 远程 origin/x → 切换同名本地分支(git switch 会自动跟踪)
                let remote = String(entry.id.dropFirst(7))
                let local = remote.split(separator: "/", maxSplits: 1).last.map(String.init) ?? remote
                Task { await model.checkout(local) }
            }
        }
    }

    /// 「删除分支」子菜单(从分支选择器移出,放在更多菜单里)。
    @ViewBuilder
    private var deleteBranchMenu: some View {
        let deletable = model.branches.filter { !$0.isRemote && !$0.isCurrent }
        if !deletable.isEmpty {
            Menu("删除分支") {
                ForEach(deletable) { branch in
                    Button(branch.name, role: .destructive) {
                        if GitDialogs.confirmDestructive(title: String(localized: "删除分支 \(branch.name)?"), message: String(localized: "未合并的提交可能丢失。"), button: String(localized: "删除")) {
                            Task { await model.deleteBranch(branch.name) }
                        }
                    }
                }
            }
        }
    }

    private var branchTitle: String {
        if let branch = model.status.branch { return branch }
        if model.status.isDetached { return String(localized: "游离 HEAD") }
        return String(localized: "无提交")
    }

    private func syncButton(icon: String, count: Int, help: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 2) {
                Image.om(icon, size: 12)
                if count > 0 { Text("\(count)").font(OMFonts.caption) }
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(count > 0 ? OMColors.accent : OMColors.secondaryText)
        .disabled(model.busy != nil)
        .help(help)
        .accessibilityLabel(Text(help))
    }

    private var moreMenu: some View {
        Menu {
            Button("获取(fetch)") { Task { await model.fetch() } }
            Button("拉取并 rebase") { Task { await model.pull(rebase: true) } }
                .disabled(model.status.upstream == nil)
            if !model.status.conflicts.isEmpty {
                Button("中止合并", role: .destructive) {
                    if GitDialogs.confirmDestructive(title: String(localized: "中止合并?"), message: String(localized: "合并中的改动与冲突解决进度会被放弃,回到合并前的状态。"), button: String(localized: "中止合并")) {
                        Task { await model.abortMerge() }
                    }
                }
            }
            Button("刷新") { Task { await model.refresh() } }
            Button("在标签页打开提交历史") { workbench.openHistory(project: model.projectPath) }
            deleteBranchMenu
            Divider()
            Button("暂存当前更改到 stash…") {
                if let message = GitDialogs.prompt(title: String(localized: "暂存到 stash"), message: String(localized: "包含未跟踪文件。可留空使用默认说明。"), placeholder: String(localized: "说明(可选)"), confirm: String(localized: "暂存")) {
                    Task { await model.stashPush(message: message) }
                } else if GitDialogs.confirmDestructive(title: String(localized: "不填写说明直接暂存?"), message: "", button: String(localized: "暂存")) {
                    Task { await model.stashPush(message: nil) }
                }
            }
            .disabled(model.status.isClean)
            if !model.stashes.isEmpty {
                Menu("Stash") {
                    ForEach(model.stashes) { stash in
                        Menu("\(stash.index): \(stash.message)") {
                            Button("应用并移除(pop)") {
                                if GitDialogs.confirmDestructive(title: String(localized: "应用并移除这个 stash?"), message: String(localized: "与当前改动冲突时可能产生合并冲突。"), button: String(localized: "应用")) {
                                    Task { await model.stashPop(stash.index) }
                                }
                            }
                            Button("丢弃", role: .destructive) {
                                if GitDialogs.confirmDestructive(title: String(localized: "丢弃这个 stash?"), message: stash.message, button: String(localized: "丢弃")) {
                                    Task { await model.stashDrop(stash.index) }
                                }
                            }
                        }
                    }
                }
            }
        } label: {
            Image.om("ellipsis", size: 14)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("更多 Git 操作")
    }

    // MARK: 提交框

    private var commitBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if model.status.isClean {
                    Text("工作区干净").font(OMFonts.small).foregroundStyle(OMColors.secondaryText)
                } else {
                    Text("未提交").font(OMFonts.small).foregroundStyle(OMColors.secondaryText)
                    Text("+\(model.stats.added)").foregroundStyle(OMColors.diffAdded)
                    Text("−\(model.stats.removed)").foregroundStyle(OMColors.diffRemoved)
                    Text("· \(model.status.changes.count) 个文件").foregroundStyle(OMColors.tertiaryText)
                }
                Spacer()
            }
            .font(OMFonts.small)
            HStack(alignment: .bottom, spacing: 4) {
                TextField("Message (⌘↩ to commit on \"\(branchTitle)\")", text: $model.commitMessage, axis: .vertical)
                    .lineLimit(2...5)
                    .textFieldStyle(.plain)
                    .font(OMFonts.small)
                    .onSubmit {
                        if canCommit { requestCommit(push: false) }
                    }

                Button {
                    Task { await model.generateCommitMessage(gateway: workbench.activeSession?.utilityGateway) }
                } label: {
                    if model.isGeneratingCommitMessage {
                        ProgressView()
                            .controlSize(.mini)
                            .frame(width: 20, height: 20)
                    } else {
                        Image.om("sparkles", size: 13)
                            .foregroundStyle(OMColors.accent)
                            .frame(width: 20, height: 20)
                    }
                }
                .buttonStyle(.plain)
                .disabled(model.isGeneratingCommitMessage || (model.status.changes.isEmpty && model.status.untrackedChanges.isEmpty))
                .omTooltip("根据改动与最近提交风格生成提交说明", icon: "sparkles")
            }
            .padding(8)
            .background(OMColors.subtleFill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(OMColors.hairline.opacity(0.6), lineWidth: 0.5))

            if syncMode {
                // 提交完成后(与 Cursor/VS Code 一致):主按钮变成「同步更改」,再点一次即拉取并推送到远端
                syncChangesButton
                Button("修补上一条提交") { Task { await model.setAmend(true) } }
                    .buttonStyle(.omPlain)
                    .disabled(model.busy != nil)
            } else {
                HStack(spacing: 2) {
                    Button { requestCommit(push: false) } label: {
                        HStack(spacing: 5) {
                            Image.om("check", size: 12)
                            Text(model.amend ? String(localized: "修补提交") : (model.status.stagedChanges.isEmpty ? String(localized: "Commit") : String(localized: "Commit (Staged)")))
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.omPositive)
                    .controlSize(.small)
                    .disabled(!canCommit)
                    .keyboardShortcut(.return, modifiers: [.command])

                    Menu {
                        Button("Commit & Push") { requestCommit(push: true) }
                        Button(model.amend ? "取消修补" : "修补上一条提交 (Amend)") {
                            Task { await model.setAmend(!model.amend) }
                        }
                        Button("暂存全部并提交") {
                            Task {
                                await model.stageAll()
                                await model.commit(push: false)
                            }
                        }
                    } label: {
                        Image.om("chevron-down", size: 10)
                            .frame(width: 22, height: 24)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .background(canCommit ? OMColors.actionPositive : OMColors.subtleFill)
                    .foregroundStyle(canCommit ? OMColors.onPositive : OMColors.tertiaryText)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }
            if model.amend, model.status.ahead == 0, model.status.upstream != nil {
                Text("上一次提交已推送,修补后需要强制推送。").font(OMFonts.caption).foregroundStyle(OMColors.warning)
            }
            if !model.status.conflicts.isEmpty {
                Text("存在冲突,解决后才能提交。").font(OMFonts.caption).foregroundStyle(OMColors.warning)
            }
        }
        .padding(10)
    }

    /// 没有可提交的内容、也不在修补提交时:有待同步的提交(或分支尚未发布)就进入「同步」模式。
    private var syncMode: Bool {
        guard model.committableCount == 0, !model.amend, model.status.conflicts.isEmpty,
              model.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              model.status.branch != nil else { return false }
        if model.status.upstream != nil { return model.status.ahead > 0 || model.status.behind > 0 }
        return model.branches.contains { $0.isRemote }
    }

    /// 「同步更改 ↓n ↑m」/「发布分支」主按钮。
    private var syncChangesButton: some View {
        let published = model.status.upstream != nil
        return Button { Task { await model.sync() } } label: {
            HStack(spacing: 6) {
                if model.busy != nil {
                    ProgressView().controlSize(.mini)
                } else {
                    Image.om(published ? "refresh-cw" : "arrow-up", size: 12)
                }
                Text(published ? String(localized: "同步更改") : String(localized: "发布分支"))
                if published {
                    HStack(spacing: 3) {
                        if model.status.behind > 0 { Text("↓\(model.status.behind)") }
                        if model.status.ahead > 0 { Text("↑\(model.status.ahead)") }
                    }
                    .font(OMFonts.caption)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.omPrimary)
        .disabled(model.busy != nil)
        .help(published ? String(localized: "先拉取远端新提交,再推送本地提交") : String(localized: "把当前分支推送到远程并建立跟踪"))
    }

    /// 提交:没有暂存内容时先确认「将提交全部改动」,避免静默 `git add -A`。
    private func requestCommit(push: Bool) {
        if model.status.stagedChanges.isEmpty, !model.amend {
            let count = model.committableCount
            guard GitDialogs.confirmDestructive(
                title: String(localized: "没有已暂存的更改,提交全部 \(count) 个文件?"),
                message: String(localized: "将先暂存所有改动(包含未跟踪文件)再提交。"),
                button: String(localized: "提交全部")
            ) else { return }
        }
        Task { await model.commit(push: push) }
    }

    private var canCommit: Bool {
        model.busy == nil && model.status.conflicts.isEmpty && (model.committableCount > 0 || model.amend)
            && !model.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: 变更列表

    private var changeList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                let conflicts = model.status.conflicts
                if !conflicts.isEmpty {
                    SectionHeader(title: "冲突", count: conflicts.count, tint: OMColors.warning) { EmptyView() }
                    ForEach(conflicts) { change in
                        ChangeRow(workbench: workbench, model: model, change: change, section: .conflict)
                    }
                }
                let staged = model.status.stagedChanges
                if !staged.isEmpty {
                    SectionHeader(title: "已暂存的更改", count: staged.count) {
                        iconButton("minus", "全部取消暂存") { Task { await model.unstageAll() } }
                    }
                    ForEach(staged) { change in ChangeRow(workbench: workbench, model: model, change: change, section: .staged) }
                }
                let unstaged = model.status.unstagedChanges
                if !unstaged.isEmpty {
                    SectionHeader(title: "更改", count: unstaged.count) {
                        iconButton("arrow-left-right", "与主分支对比") {
                            workbench.openDiff(model.absolutePath(unstaged[0].path))
                        }
                        iconButton("undo-2", "放弃全部更改") {
                            if GitDialogs.confirmDestructive(title: String(localized: "放弃全部 \(unstaged.count) 个文件的更改?"), message: String(localized: "此操作不可撤销。"), button: String(localized: "放弃更改")) {
                                Task { await model.discard(unstaged.map(\.path)) }
                            }
                        }
                        iconButton("plus", "全部暂存") { Task { await model.stage(unstaged.map(\.path)) } }
                    }
                    ForEach(unstaged) { change in ChangeRow(workbench: workbench, model: model, change: change, section: .unstaged) }
                }
                let untracked = model.status.untrackedChanges
                if !untracked.isEmpty {
                    SectionHeader(title: "未跟踪的文件", count: untracked.count) {
                        iconButton("plus", "全部暂存") { Task { await model.stage(untracked.map(\.path)) } }
                    }
                    ForEach(untracked) { change in ChangeRow(workbench: workbench, model: model, change: change, section: .untracked) }
                }
                GitGraphSection(workbench: workbench, model: model)
            }
            .padding(.vertical, 4)
        }
    }

    private func iconButton(_ icon: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image.om(icon, size: 12) }
            .buttonStyle(.plain).foregroundStyle(OMColors.secondaryText)
            .disabled(model.busy != nil)
            .omTooltip(help, icon: icon)
            .accessibilityLabel(help)
    }

    // MARK: 其他状态

    private var notRepository: some View {
        OMEmptyState {
            Label("这个文件夹还不是 Git 仓库", om: "git-branch", size: 28)
        } description: {
            Text("初始化后可以查看改动、提交并推送。")
        } actions: {
            Button("初始化仓库") { Task { await model.initializeRepository() } }
                .disabled(model.busy != nil)
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image.om("triangle-alert", size: 12).foregroundStyle(OMColors.warning)
            Text(message).font(OMFonts.caption).lineLimit(6).textSelection(.enabled)
            Spacer(minLength: 0)
            Button { model.lastError = nil } label: { Image.om("xmark", size: 10) }
                .buttonStyle(.plain).accessibilityLabel("关闭提示")
        }
        .padding(8)
        .background(OMColors.warning.opacity(0.12))
    }
}

// MARK: - 分组头与行

private struct SectionHeader<Actions: View>: View {
    let title: LocalizedStringKey
    let count: Int
    var tint: Color = OMColors.secondaryText
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(OMFonts.caption.weight(.semibold)).foregroundStyle(tint)
            Text("\(count)").font(OMFonts.caption).foregroundStyle(OMColors.tertiaryText)
            Spacer()
            actions()
        }
        .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 3)
    }
}

enum ChangeSection { case conflict, staged, unstaged, untracked }

private struct ChangeRow: View {
    let workbench: WorkbenchModel
    let model: GitModel
    let change: GitFileChange
    let section: ChangeSection
    @State private var hovering = false

    private var kind: GitChangeKind? {
        switch section {
        case .staged: return change.staged
        case .unstaged: return change.unstaged
        case .untracked: return .added
        case .conflict: return nil
        }
    }

    var body: some View {
        let name = (change.path as NSString).lastPathComponent
        let dir = (change.path as NSString).deletingLastPathComponent
        HStack(spacing: 6) {
            OMFileIcon(name: name, size: 14)
            Text(name).font(OMFonts.small).lineLimit(1).layoutPriority(2)
            if !dir.isEmpty {
                Text(dir).font(OMFonts.caption).foregroundStyle(OMColors.tertiaryText).lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: 4)
            if hovering { actions }
            badge
        }
        .padding(.horizontal, 10)
        .frame(height: 24)   // 固定行高:悬停出现操作按钮时不改变高度
        .contentShape(Rectangle())
        .background(hovering ? OMColors.hoverFill : .clear)
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { workbench.openFile(model.absolutePath(change.path), preview: false) }
        .onTapGesture { openDiff() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(name + (dir.isEmpty ? "" : "," + dir))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: Text("查看差异")) { openDiff() }
        .accessibilityAction(named: Text("在编辑器中打开")) { workbench.openFile(model.absolutePath(change.path), preview: false) }
        .contextMenu {
            Button("查看差异") { openDiff() }
            Button("在编辑器中打开") { workbench.openFile(model.absolutePath(change.path), preview: false) }
            if !change.isUntracked {
                Button("Git 历史") { workbench.openHistory(project: model.projectPath, path: model.absolutePath(change.path)) }
                Button("Git Blame") { workbench.openBlame(model.absolutePath(change.path)) }
            }
            Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: model.absolutePath(change.path))]) }
            Button("拷贝路径") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(change.path, forType: .string)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(change.path) \(kind?.badge ?? "U")")
    }

    private func openDiff() { workbench.openDiff(model.absolutePath(change.path)) }

    /// 冲突整文件取一方会丢掉另一方的修改,先确认。
    private func confirmResolve(_ resolution: GitConflictResolution) {
        let name = (change.path as NSString).lastPathComponent
        let title = resolution == .ours ? String(localized: "整个文件保留我的版本?") : String(localized: "整个文件采用对方的版本?")
        if GitDialogs.confirmDestructive(title: title, message: String(localized: "\(name) 中另一方的修改会被丢弃。"), button: String(localized: "确认")) {
            Task { await model.resolve(change.path, with: resolution) }
        }
    }

    @ViewBuilder
    private var actions: some View {
        rowButton("arrow.up.forward.square", "在编辑器中打开") { workbench.openFile(model.absolutePath(change.path), preview: false) }
        switch section {
        case .staged:
            rowButton("minus", "取消暂存") { Task { await model.unstage([change.path]) } }
        case .unstaged:
            rowButton("undo-2", "放弃更改") {
                if GitDialogs.confirmDestructive(title: String(localized: "放弃 \((change.path as NSString).lastPathComponent) 的更改?"), message: String(localized: "此操作不可撤销。"), button: String(localized: "放弃更改")) {
                    Task { await model.discard([change.path]) }
                }
            }
            rowButton("plus", "暂存") { Task { await model.stage([change.path]) } }
        case .untracked:
            rowButton("trash", "删除文件") {
                if GitDialogs.confirmDestructive(title: String(localized: "删除 \((change.path as NSString).lastPathComponent)?"), message: String(localized: "此操作不可撤销。"), button: String(localized: "删除")) {
                    Task { await model.discard([], untracked: [change.path]) }
                }
            }
            rowButton("plus", "暂存") { Task { await model.stage([change.path]) } }
        case .conflict:
            Button("保留我的") { confirmResolve(.ours) }.buttonStyle(.plain).font(OMFonts.caption).foregroundStyle(OMColors.accent)
            Button("采用对方") { confirmResolve(.theirs) }.buttonStyle(.plain).font(OMFonts.caption).foregroundStyle(OMColors.accent)
            rowButton("check", "标记已解决") { Task { await model.markResolved(change.path) } }
        }
    }

    private func rowButton(_ icon: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image.om(icon, size: 12) }
            .buttonStyle(.plain).foregroundStyle(OMColors.secondaryText)
            .disabled(model.busy != nil)
            .omTooltip(help, icon: icon)
            .accessibilityLabel(help)
    }

    private var badge: some View {
        Text(section == .conflict ? "!" : (kind?.badge ?? ""))
            .font(OMFonts.caption.weight(.semibold))
            .foregroundStyle(badgeColor)
            .frame(width: 14)
    }

    private var badgeColor: Color {
        if section == .conflict { return OMColors.warning }
        switch kind {
        case .added: return OMColors.diffAdded
        case .deleted: return OMColors.diffRemoved
        case .modified, .typeChanged: return OMColors.warning
        case .renamed, .copied: return OMColors.accent
        case nil: return OMColors.secondaryText
        }
    }
}
