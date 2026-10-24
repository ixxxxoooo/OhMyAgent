// @author ixxxxoooo
// Git 页(源代码管理)里的两个可折叠分区,对齐 VSCode/Cursor 的信息架构:
// ① 「本轮 Agent 改动」:当前会话最近一次改动汇总(原右栏「改动」页并入此处);
// ② 「提交图谱」:最近提交与泳道图,点击提交在原地展开文件列表与内联差异,完整历史标签由右上角按钮打开。

import AppKit
import ChatKit
import DesignSystem
import DiffKit
import GitKit
import IconKit
import OMLog
import SwiftUI
import WorkbenchKit

/// 可折叠分区标题:左侧箭头 + 标题 + 数量,右侧放操作。
private struct CollapsibleHeader<Actions: View>: View {
    let title: LocalizedStringKey
    let count: Int?
    @Binding var expanded: Bool
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(spacing: 4) {
            Button {
                omWithAnimation(.snappy(duration: 0.16)) { expanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image.om("chevron-right", size: 10, weight: .bold)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .frame(width: 12)
                    Text(title).font(OMFonts.caption.weight(.medium))
                    if let count { Text("\(count)").font(OMFonts.caption).foregroundStyle(OMColors.tertiaryText) }
                    Spacer(minLength: 0)
                }
                .foregroundStyle(OMColors.secondaryText)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(expanded ? String(localized: "收起") : String(localized: "展开"))
            actions()
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
    }
}

/// 「提交图谱」分区:最近提交(含所有分支)的泳道图,滚动到底自动加载更早的提交;
/// 点击一行在原地展开该提交的文件列表,点文件再展开内联差异(对标 VS Code 的 Source Control Graph);
/// 右上角按钮才打开完整历史标签。
struct GitGraphSection: View {
    let host: any SCMHost
    let model: GitModel
    @State private var expanded = true
    @State private var rows: [GitGraphRow] = []
    @State private var failed = false
    /// 当前展开的提交(同一时间只展开一个)
    @State private var expandedHash: String?
    /// 首次与每次滚动到底追加的提交数
    private static let pageSize = 30
    /// 当前请求的提交条数(滚动到底时递增)
    @State private var limit = 30
    /// 是否可能还有更早的提交
    @State private var hasMore = false
    @State private var loadingMore = false
    /// 底部加载哨兵是否在可见区域
    @State private var sentinelVisible = false

    /// 状态变化(分支切换、提交/推送/拉取、工作区变干净)时重新取数。
    private var reloadKey: String {
        "\(model.status.branch ?? "-")#\(model.status.ahead)#\(model.status.behind)#\(model.status.isClean)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CollapsibleHeader(title: "提交图谱", count: nil, expanded: $expanded) {
                Button { host.openHistory(project: model.projectPath, path: nil) } label: {
                    Image.om("external-link", size: 12)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(OMColors.secondaryText)
                .omTooltip("在标签页打开完整历史")
                .accessibilityLabel("打开完整提交历史")
            }
            if expanded {
                if rows.isEmpty {
                    Text(failed ? String(localized: "无法读取提交历史") : String(localized: "还没有提交"))
                        .font(OMFonts.small)
                        .foregroundStyle(OMColors.tertiaryText)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                } else {
                    let laneWidth = CGFloat(max(1, rows.map(\.laneCount).max() ?? 1)) * 14 + 10
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { row in
                            let isOpen = expandedHash == row.commit.hash
                            CommitRow(row: row, laneWidth: laneWidth, isSelected: isOpen, compact: true)
                                .onTapGesture { omWithAnimation { expandedHash = isOpen ? nil : row.commit.hash } }
                                .accessibilityElement(children: .combine)
                                .accessibilityAddTraits(.isButton)
                                .accessibilityHint(isOpen ? String(localized: "点按收起文件列表") : String(localized: "点按展开文件列表"))
                                .omContextMenu {
                                    OMMenuItem("拷贝提交哈希", icon: "copy") {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(row.commit.hash, forType: .string)
                                    }
                                    OMMenuItem("打开完整历史", icon: "git-commit-horizontal") { host.openHistory(project: model.projectPath, path: nil) }
                                }
                            if isOpen, let repo = model.repo {
                                GraphCommitDetail(repo: repo, commit: row.commit, host: host)
                                    .id(row.commit.hash)
                            }
                        }
                        if hasMore {
                            // 滚动到底部哨兵时自动加载下一页
                            OMSpinner(.mini)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                // 非结构化任务:行数变化会使视图任务被取消,不能把加载放在 .task 里
                            .onAppear { sentinelVisible = true; Task { await loadMore() } }
                            .onDisappear { sentinelVisible = false }
                            .onChange(of: rows.count) { if sentinelVisible { Task { await loadMore() } } }
                        }
                    }
                }
            }
        }
        .padding(.bottom, 8)
        .task(id: reloadKey) { await load() }
    }

    /// 滚动到底时多取一页(重新取前 N 条并整体布局,保证泳道连续)。
    private func loadMore() async {
        guard hasMore, !loadingMore else { return }
        loadingMore = true
        let previous = limit
        limit += Self.pageSize
        Log.git.info("提交图谱加载更多", ["from": "\(previous)", "to": "\(limit)", "rows": "\(rows.count)"])
        if !(await load()), limit == previous + Self.pageSize { limit = previous; hasMore = false }
        loadingMore = false
    }

    /// 取数并布局;返回是否成功。取数期间仓库状态或条数又变了(提交/拉取、并发的加载更多),结果作废不覆盖新数据。
    @discardableResult
    private func load() async -> Bool {
        let key = reloadKey, requested = limit
        guard let repo = await GitRepository.discover(from: model.projectPath) else {
            rows = []
            hasMore = false
            return false
        }
        do {
            let started = ContinuousClock.now
            let commits = try await repo.log(limit: requested, path: nil, all: true)
            guard reloadKey == key, limit == requested else {
                Log.git.debug("提交图谱结果已过期,丢弃", ["limit": "\(requested)"])
                return true
            }
            let fetched = OMLogger.milliseconds(since: started)
            rows = GitGraph.layout(commits)
            Log.git.info("提交图谱已加载", ["limit": "\(limit)", "commits": "\(commits.count)", "fetchMs": "\(fetched)"])
            hasMore = commits.count >= requested && requested < 5000
            failed = false
            return true
        } catch {
            Log.git.warning("提交图谱加载失败", ["limit": "\(limit)", "error": "\(error)"])
            failed = true
            return false
        }
    }
}

/// 图谱里展开的提交详情:作者/时间/哈希 + 变更文件列表;点文件在原地展开内联差异。
private struct GraphCommitDetail: View {
    let repo: GitRepository
    let commit: GitCommit
    let host: any SCMHost
    @State private var files: [GitFileChange] = []
    @State private var loaded = false
    @State private var openFile: String?
    @State private var diff: FileDiff?
    @State private var binary = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(commit.author)
                Text(commit.date, format: .dateTime.month().day().hour().minute())
                Text(commit.shortHash).font(OMFonts.monoSmall)
                if commit.isMerge { OMTag(String(localized: "合并"), tint: OMColors.accent2) }
                Spacer(minLength: 0)
            }
            .font(OMFonts.caption)
            .foregroundStyle(OMColors.secondaryText)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            if !loaded {
                OMSpinner(.small).frame(maxWidth: .infinity).padding(6)
            } else if files.isEmpty {
                Text("这个提交没有文件改动(例如空的合并提交)。").font(OMFonts.caption).foregroundStyle(OMColors.tertiaryText)
                    .padding(.horizontal, 12).padding(.vertical, 4)
            }
            ForEach(files) { file in
                fileRow(file)
                if openFile == file.path { inlineDiff }
            }
        }
        .padding(.bottom, 4)
        .background(OMColors.selectedFill)
        .task { await loadFiles() }
        .task(id: openFile) { await loadDiff() }
    }

    private func fileRow(_ file: GitFileChange) -> some View {
        let name = (file.path as NSString).lastPathComponent
        let dir = (file.path as NSString).deletingLastPathComponent
        let kind = file.staged ?? file.unstaged
        return HStack(spacing: 6) {
            OMFileIcon(name: name, isDirectory: false, expanded: false, size: 14)
            Text(name).font(OMFonts.small).lineLimit(1)
            if !dir.isEmpty {
                Text(dir).font(OMFonts.caption).foregroundStyle(OMColors.tertiaryText).lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: 4)
            Text(kind?.badge ?? "").font(OMFonts.caption.weight(.medium)).foregroundStyle(color(kind))
        }
        .padding(.horizontal, 12).padding(.vertical, 3)
        .background(openFile == file.path ? OMColors.selectedFill : .clear)
        .contentShape(Rectangle())
        .onTapGesture { omWithAnimation { openFile = openFile == file.path ? nil : file.path } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .omContextMenu {
            OMMenuItem("在编辑器中打开当前版本", icon: "file-text") { host.openFile(repo.root.path + "/" + file.path, preview: false) }
            OMMenuItem("文件历史", icon: "clock") { host.openHistory(project: repo.root.path, path: repo.root.path + "/" + file.path) }
        }
    }

    @ViewBuilder
    private var inlineDiff: some View {
        if let diff {
            // 侧栏较窄,正文自动换行;DiffView 自带 300 行软上限,无需再套滚动容器
            DiffView(diff: diff)
                .padding(.horizontal, 8).padding(.vertical, 4)
        } else if binary {
            Text("二进制文件,不显示差异。").font(OMFonts.caption).foregroundStyle(OMColors.secondaryText).padding(.horizontal, 12).padding(.vertical, 4)
        } else {
            OMSpinner(.small).frame(maxWidth: .infinity).padding(6)
        }
    }

    private func color(_ kind: GitChangeKind?) -> Color {
        switch kind {
        case .added: return OMColors.diffAdded
        case .deleted: return OMColors.diffRemoved
        case .renamed, .copied: return OMColors.accent
        default: return OMColors.warning
        }
    }

    private func loadFiles() async {
        files = (try? await repo.files(in: commit.hash)) ?? []
        loaded = true
    }

    private func loadDiff() async {
        diff = nil
        binary = false
        guard let openFile else { return }
        do {
            let result = try await repo.fileDiff(path: openFile, commit: commit.hash)
            diff = result
            binary = result == nil
        } catch {
            binary = false
        }
    }
}
