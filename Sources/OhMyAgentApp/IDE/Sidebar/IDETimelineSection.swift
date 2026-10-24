// @author ixxxxoooo
// 资源管理器下方的「时间线」折叠区:列出活动文件的 Git 提交历史(`git log --follow`),点击打开文件历史标签。
// 没有仓库或文件未被跟踪时显示占位文案;随活动文件与仓库 HEAD 变化刷新。

import DesignSystem
import GitKit
import IconKit
import SwiftUI

extension IDEWorkspace {
    /// 刷新活动文件的时间线(活动文件切换、HEAD 变化后调用;最多取 50 条)。
    func refreshTimeline() {
        timelineTask?.cancel()
        guard let root, let path = model.activeFilePath else {
            timeline = []
            timelinePath = nil
            return
        }
        timelineTask = Task { [weak self] in
            let git = GitStore.shared.model(for: root)
            if git.repo == nil { await git.refresh(full: false) }
            guard let repo = git.repo, let relative = repo.relativePath(of: path) else {
                self?.timeline = []
                self?.timelinePath = path
                return
            }
            let commits = (try? await repo.log(limit: 50, path: relative)) ?? []
            guard !Task.isCancelled, let self, self.model.activeFilePath == path else { return }
            self.timeline = commits
            self.timelinePath = path
        }
    }
}

struct IDETimelineSection: View {
    let workspace: IDEWorkspace
    @AppStorage("ide.timelineExpanded") private var expanded = false

    /// 提交列表:新文件的历史到位前继续显示上一个文件的,切换时区域尺寸与内容不跳变。
    private var commits: [GitCommit] {
        workspace.model.activeFilePath == nil ? [] : workspace.timeline
    }

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(OMColors.hairline).frame(height: 1)
            Button { expanded.toggle() } label: {
                HStack(spacing: 4) {
                    Image.om(expanded ? "chevron-down" : "chevron-right", size: 12)
                    Text("时间线").font(OMFonts.caption)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(OMColors.secondaryText)
                .padding(.horizontal, 12)
                .frame(height: 26)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "时间线"))
            if expanded {
                let items = commits
                if items.isEmpty {
                    Text(workspace.model.activeFilePath == nil ? String(localized: "没有打开的文件") : String(localized: "没有提交历史"))
                        .font(OMFonts.small)
                        .foregroundStyle(OMColors.tertiaryText)
                        .frame(maxWidth: .infinity, minHeight: 180)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(items) { commit in
                                TimelineRow(commit: commit) { open() }
                            }
                        }
                    }
                    .frame(height: 180)
                }
            }
        }
        .task(id: refreshKey) { if expanded { workspace.refreshTimeline() } }
    }

    /// 刷新键:活动文件 + 仓库 HEAD + 展开状态。
    private var refreshKey: String {
        let head = workspace.root.map { GitStore.shared.model(for: $0).status.headOID ?? "" } ?? ""
        return "\(workspace.model.activeFilePath ?? "")|\(head)|\(expanded)"
    }

    private func open() {
        guard let root = workspace.root, let path = workspace.model.activeFilePath else { return }
        workspace.model.openHistory(project: root, path: path)
    }
}

private struct TimelineRow: View {
    let commit: GitCommit
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image.om("git-commit-horizontal", size: 12).foregroundStyle(OMColors.secondaryText)
                VStack(alignment: .leading, spacing: 0) {
                    Text(commit.subject).font(OMFonts.small).foregroundStyle(OMColors.primaryText).lineLimit(1)
                    Text("\(commit.author) · \(Self.relative(commit.date))").font(OMFonts.caption).foregroundStyle(OMColors.tertiaryText).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(hovering ? OMColors.hoverFill : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    /// 相对时间(如「3 天前」)。
    static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
