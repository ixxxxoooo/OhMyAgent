// @author ygw
// 源代码管理面板:分支、同步、提交框、冲突/已暂存/更改/未跟踪分组;点击文件打开 Diff 标签。

import AppKit
import DesignSystem
import GitKit
import IconKit
import SwiftUI
import WorkbenchKit

/// 右栏「改动」里的 Git 视图。
struct SCMView: View {
    let workbench: WorkbenchModel

    var body: some View {
        if let project = workbench.selectedProject {
            SCMContent(workbench: workbench, model: GitStore.shared.model(for: project.id))
                .id(project.id)
        } else {
            ContentUnavailableView { Label("没有项目", om: "folder", size: 28) } description: { Text("添加一个项目后,这里会显示它的 Git 状态。") }
        }
    }
}

private struct SCMContent: View {
    let workbench: WorkbenchModel
    @Bindable var model: GitModel

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
            // 面板可见期间轮询;操作完成后另有即时刷新
            while !Task.isCancelled {
                await model.refresh(full: model.branches.isEmpty)
                try? await Task.sleep(for: .seconds(3))
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

    private var branchMenu: some View {
        Menu {
            let locals = model.branches.filter { !$0.isRemote }
            let remotes = model.branches.filter(\.isRemote)
            ForEach(locals) { branch in
                Button {
                    if !branch.isCurrent { Task { await model.checkout(branch.name) } }
                } label: {
                    if branch.isCurrent { Label(branch.name, om: "check", size: 12) } else { Text(branch.name) }
                }
            }
            if !remotes.isEmpty {
                Menu("远程分支") {
                    ForEach(remotes) { branch in
                        Button(branch.name) {
                            // 远程 origin/x → 切换同名本地分支(git switch 会自动跟踪)
                            let local = branch.name.split(separator: "/", maxSplits: 1).last.map(String.init) ?? branch.name
                            Task { await model.checkout(local) }
                        }
                    }
                }
            }
            Divider()
            Button("新建分支…") {
                if let name = GitDialogs.prompt(title: String(localized: "新建分支"), message: String(localized: "基于当前提交创建并切换到新分支。"), placeholder: "feature/xxx", confirm: String(localized: "创建")) {
                    Task { await model.createBranch(name) }
                }
            }
            let deletable = locals.filter { !$0.isCurrent }
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
        } label: {
            HStack(spacing: 4) {
                Image.om("git-branch", size: 12)
                Text(branchTitle).font(OMFonts.small.weight(.semibold)).lineLimit(1)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .fixedSize()
        .accessibilityLabel("切换分支")
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
            Button("刷新") { Task { await model.refresh() } }
            Button("查看提交历史") { workbench.openHistory(project: model.projectPath) }
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
                            Button("应用并移除(pop)") { Task { await model.stashPop(stash.index) } }
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
            TextField("提交信息", text: $model.commitMessage, axis: .vertical)
                .lineLimit(2...5)
                .textFieldStyle(.plain)
                .font(OMFonts.small)
                .padding(8)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            HStack(spacing: 6) {
                Button { Task { await model.commit() } } label: {
                    Text(model.status.stagedChanges.isEmpty ? "提交全部" : "提交").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!canCommit)
                Button { Task { await model.commit(push: true) } } label: {
                    Text("提交并推送")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!canCommit)
            }
            if !model.status.conflicts.isEmpty {
                Text("存在冲突,解决后才能提交。").font(OMFonts.caption).foregroundStyle(OMColors.warning)
            }
        }
        .padding(10)
    }

    private var canCommit: Bool {
        model.busy == nil && model.status.conflicts.isEmpty && model.committableCount > 0
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
            }
            .padding(.vertical, 4)
        }
    }

    private func iconButton(_ icon: String, _ help: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image.om(icon, size: 12) }
            .buttonStyle(.plain).foregroundStyle(OMColors.secondaryText)
            .disabled(model.busy != nil)
            .help(help).accessibilityLabel(Text(help))
    }

    // MARK: 其他状态

    private var notRepository: some View {
        ContentUnavailableView {
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
            Image.om("file-code", size: 12).foregroundStyle(OMColors.secondaryText)
            Text(name).font(OMFonts.small).lineLimit(1)
            if !dir.isEmpty {
                Text(dir).font(OMFonts.caption).foregroundStyle(OMColors.tertiaryText).lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: 4)
            if hovering { actions }
            badge
        }
        .padding(.horizontal, 10).padding(.vertical, 3)
        .contentShape(Rectangle())
        .background(hovering ? Color.primary.opacity(0.06) : .clear)
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

    @ViewBuilder
    private var actions: some View {
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
            Button("保留我的") { Task { await model.resolve(change.path, with: .ours) } }.buttonStyle(.plain).font(OMFonts.caption).foregroundStyle(OMColors.accent)
            Button("采用对方") { Task { await model.resolve(change.path, with: .theirs) } }.buttonStyle(.plain).font(OMFonts.caption).foregroundStyle(OMColors.accent)
            rowButton("check", "标记已解决") { Task { await model.markResolved(change.path) } }
        }
    }

    private func rowButton(_ icon: String, _ help: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image.om(icon, size: 12) }
            .buttonStyle(.plain).foregroundStyle(OMColors.secondaryText)
            .disabled(model.busy != nil)
            .help(help).accessibilityLabel(Text(help))
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
