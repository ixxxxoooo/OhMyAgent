// @author ixxxxoooo
// IDE 侧栏「源代码管理」视图:分支与同步、提交说明与提交、冲突/暂存/更改/未跟踪四个分组,
// 行点击在编辑器里打开差异,双击打开文件;暂存、取消暂存、丢弃都走共享的 `GitModel`。

import ChatKit
import DesignSystem
import GitKit
import IconKit
import IDEKit
import SwiftUI

struct IDESCMPane: View {
    let workspace: IDEWorkspace

    var body: some View {
        if let root = workspace.root {
            let model = GitStore.shared.model(for: root)
            switch model.phase {
            case .notRepository:
                OMEmptyState {
                    Label("不是 Git 仓库", om: "git-branch")
                } description: {
                    Text("在此文件夹初始化仓库后即可管理改动")
                } actions: {
                    Button("初始化仓库") { Task { await model.initializeRepository() } }
                }
            default:
                IDESCMContent(workspace: workspace, model: model)
                    .task(id: root) { await model.refresh(full: true) }
            }
        }
    }
}

/// 仓库就绪后的内容。
private struct IDESCMContent: View {
    let workspace: IDEWorkspace
    let model: GitModel

    private var status: GitStatus { model.status }

    var body: some View {
        VStack(spacing: 0) {
            branchBar
            commitBox
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: []) {
                    section("冲突", id: "conflict", changes: status.conflicts, actions: [])
                    section("暂存的更改", id: "staged", changes: status.stagedChanges, actions: [
                        ("minus", String(localized: "全部取消暂存"), { Task { await model.unstageAll() } }),
                    ])
                    section("更改", id: "unstaged", changes: status.unstagedChanges, actions: [
                        ("undo-2", String(localized: "放弃全部更改"), { discardAll() }),
                        ("plus", String(localized: "全部暂存"), { Task { await model.stageAll() } }),
                    ])
                    section("未跟踪", id: "untracked", changes: status.untrackedChanges, actions: [
                        ("plus", String(localized: "全部暂存"), { Task { await model.stage(status.untrackedChanges.map(\.path)) } }),
                    ])
                    if status.changes.isEmpty {
                        Text("没有改动").font(OMFonts.small).foregroundStyle(OMColors.tertiaryText).padding(.top, 24)
                    }
                }
                .padding(.bottom, 8)
            }
            if let error = model.lastError {
                HStack(spacing: 6) {
                    Text(error).font(OMFonts.caption).foregroundStyle(OMColors.danger).lineLimit(3)
                    Spacer(minLength: 0)
                    Button { model.lastError = nil } label: { Image.om("x", size: 12) }
                        .buttonStyle(.omIcon).accessibilityLabel(String(localized: "关闭"))
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
            }
        }
    }

    // MARK: 分支栏

    private var branchBar: some View {
        HStack(spacing: 4) {
            Image.om("git-branch", size: 14).foregroundStyle(OMColors.secondaryText)
            Text(status.branch ?? String(localized: "游离 HEAD")).font(OMFonts.small).foregroundStyle(OMColors.primaryText).lineLimit(1)
            if status.ahead > 0 || status.behind > 0 {
                Text("↑\(status.ahead) ↓\(status.behind)").font(OMFonts.caption).foregroundStyle(OMColors.tertiaryText)
            }
            Spacer(minLength: 4)
            iconButton("refresh-cw", String(localized: "刷新")) { Task { await model.refresh(full: true) } }
            iconButton("arrow-down-up", String(localized: "同步")) { Task { await model.sync() } }
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
    }

    // MARK: 提交框

    private var commitBox: some View {
        VStack(spacing: 8) {
            TextField(String(localized: "提交说明"), text: Bindable(model).commitMessage, axis: .vertical)
                .textFieldStyle(.plain)
                .font(OMFonts.small)
                .lineLimit(1...5)
                .padding(8)
                .background(OMColors.surface, in: RoundedRectangle(cornerRadius: OMRadius.control))
                .overlay(RoundedRectangle(cornerRadius: OMRadius.control).strokeBorder(OMColors.hairline, lineWidth: 1))
            Button { Task { await model.commit() } } label: {
                Text(model.busy ?? (status.stagedChanges.isEmpty ? String(localized: "提交全部") : String(localized: "提交")))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(OMButtonStyle(.primary, size: .regular))
            .disabled(model.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.busy != nil || status.changes.isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    // MARK: 分组与行

    @ViewBuilder
    private func section(_ title: LocalizedStringResource, id: String, changes: [GitFileChange],
                         actions: [(icon: String, title: String, run: () -> Void)]) -> some View {
        if !changes.isEmpty {
            HStack(spacing: 4) {
                Text(String(localized: title)).font(OMFonts.caption).foregroundStyle(OMColors.secondaryText)
                Text("\(changes.count)").font(OMFonts.caption).foregroundStyle(OMColors.tertiaryText)
                Spacer(minLength: 0)
                ForEach(Array(actions.enumerated()), id: \.offset) { _, action in iconButton(action.icon, action.title, action.run) }
            }
            .padding(.horizontal, 12)
            .frame(height: 26)
            ForEach(changes) { change in
                IDESCMRow(workspace: workspace, model: model, change: change, section: id)
            }
        }
    }

    private func iconButton(_ icon: String, _ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image.om(icon, size: 14) }
            .buttonStyle(.omIcon)
            .omTooltip(title)
            .accessibilityLabel(title)
    }

    private func discardAll() {
        let paths = status.unstagedChanges.map(\.path)
        guard OMDialog.confirm(title: String(localized: "要放弃全部 \(paths.count) 个文件的更改吗?"), message: String(localized: "此操作无法撤销。"),
                               confirmTitle: String(localized: "放弃更改"), destructive: true) else { return }
        Task { await model.discard(paths) }
    }
}

/// 一行改动。
private struct IDESCMRow: View {
    let workspace: IDEWorkspace
    let model: GitModel
    let change: GitFileChange
    let section: String
    @State private var hovering = false

    private var absolute: String { model.absolutePath(change.path) }
    private var name: String { (change.path as NSString).lastPathComponent }
    private var directory: String { (change.path as NSString).deletingLastPathComponent }
    private var kind: GitDecorationKind? { GitDecorationKind(change: change) }

    var body: some View {
        HStack(spacing: 6) {
            OMFileIcon(name: name, size: 14)
            Text(name).font(OMFonts.small).foregroundStyle(OMColors.primaryText).lineLimit(1)
            if !directory.isEmpty {
                Text(directory).font(OMFonts.caption).foregroundStyle(OMColors.tertiaryText).lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: 4)
            if hovering { actions }
            if let kind { Text(kind.letter).font(OMFonts.caption).foregroundStyle(tint(kind)).frame(width: 14) }
        }
        .padding(.horizontal, 12)
        .frame(height: 24)
        .background(model.selectedChangeKey == "\(section):\(change.path)" ? OMColors.selectedFill : (hovering ? OMColors.hoverFill : Color.clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            model.selectedChangeKey = "\(section):\(change.path)"
            if change.isUntracked { workspace.open(absolute, preview: true) } else { workspace.model.openDiff(absolute) }
        }
        .simultaneousGesture(TapGesture(count: 2).onEnded { workspace.open(absolute, preview: false) })
        .omContextMenu { menu }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(change.path)
    }

    @ViewBuilder
    private var actions: some View {
        switch section {
        case "staged":
            button("minus", String(localized: "取消暂存")) { Task { await model.unstage([change.path]) } }
        case "untracked":
            button("plus", String(localized: "暂存")) { Task { await model.stage([change.path]) } }
        default:
            button("undo-2", String(localized: "放弃更改")) { discard() }
            button("plus", String(localized: "暂存")) { Task { await model.stage([change.path]) } }
        }
    }

    private func button(_ icon: String, _ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image.om(icon, size: 12) }
            .buttonStyle(.omIcon)
            .omTooltip(title)
            .accessibilityLabel(title)
    }

    private func discard() {
        guard OMDialog.confirm(title: String(localized: "要放弃「\(name)」的更改吗?"), message: String(localized: "此操作无法撤销。"),
                               confirmTitle: String(localized: "放弃更改"), destructive: true) else { return }
        Task { await model.discard([change.path]) }
    }

    private func tint(_ kind: GitDecorationKind) -> Color {
        switch kind {
        case .modified: return OMColors.warning
        case .added, .renamed, .untracked: return OMColors.success
        case .deleted, .conflict: return OMColors.danger
        }
    }

    private var menu: [MenuEntry] {
        var items: [MenuEntry] = []
        items += OMMenuItem("打开文件", icon: "file-text") { workspace.open(absolute, preview: false) }.menuEntries
        if !change.isUntracked { items += OMMenuItem("查看差异", icon: "git-compare") { workspace.model.openDiff(absolute) }.menuEntries }
        items += OMMenuDivider().menuEntries
        switch section {
        case "staged": items += OMMenuItem("取消暂存", icon: "minus") { Task { await model.unstage([change.path]) } }.menuEntries
        default: items += OMMenuItem("暂存", icon: "plus") { Task { await model.stage([change.path]) } }.menuEntries
        }
        if section != "staged" && !change.isUntracked {
            items += OMMenuItem("放弃更改", icon: "undo-2", isDestructive: true) { discard() }.menuEntries
        }
        items += OMMenuDivider().menuEntries
        items += OMMenuItem("在文件树中显示", icon: "folder-search") { workspace.reveal(absolute) }.menuEntries
        return items
    }
}
