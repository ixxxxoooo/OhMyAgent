// @author ixxxxoooo
// Git 历史标签:左侧提交列表(含泳道图、引用徽标),右侧所选提交的文件与差异。

import AppKit
import DesignSystem
import DiffKit
import GitKit
import IconKit
import SwiftUI
import WorkbenchKit

/// 泳道颜色表。
private var laneColors: [Color] { (0..<6).map { OMColors.chart($0) } }

struct GitHistoryTabView: View {
    let workbench: WorkbenchModel
    let projectID: String
    /// 仅看某文件(绝对路径)的历史;nil 为整个仓库
    let path: String?
    @State private var repo: GitRepository?
    @State private var rows: [GitGraphRow] = []
    @State private var loaded = false
    @State private var errorMessage: String?
    @State private var selected: String?
    @State private var allBranches = true

    var body: some View {
        Group {
            if !loaded {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                OMEmptyState { Label("无法读取历史", om: "triangle-alert", size: 28) } description: { Text(errorMessage) }
            } else if repo == nil {
                OMEmptyState { Label("不是 Git 仓库", om: "git-branch", size: 28) } description: { Text("这个项目还没有 Git 历史。") }
            } else if rows.isEmpty {
                OMEmptyState { Label("还没有提交", om: "git-commit-horizontal", size: 28) } description: { Text("提交后这里会显示历史。") }
            } else {
                // 上下排布(不用 SplitView:它会按子视图理想宽度撑开,把内容挤出可视区)
                GeometryReader { proxy in
                    VStack(spacing: 0) {
                        commitList.frame(height: max(120, proxy.size.height * 0.5))
                        Divider()
                        detail.frame(maxHeight: .infinity)
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                }
            }
        }
        .task(id: "\(projectID)#\(path ?? "")#\(allBranches)") { await load() }
    }

    private func load() async {
        let start = path ?? projectID
        guard let found = await GitRepository.discover(from: start) else {
            repo = nil
            loaded = true
            return
        }
        repo = found
        do {
            var relative: String?
            if let path {
                guard let rel = found.relativePath(of: path) else { throw GitError.invalidArgument(String(localized: "文件不在仓库内")) }
                relative = rel
            }
            let commits = try await found.log(limit: 400, path: relative, all: allBranches)
            // 文件历史是被过滤的子序列,不画泳道;整库历史才画图
            rows = relative == nil ? GitGraph.layout(commits) : commits.map {
                GitGraphRow(commit: $0, column: 0, color: 0, top: [], bottom: [], incoming: [], outgoing: [])
            }
            errorMessage = nil
            if selected == nil || !rows.contains(where: { $0.commit.hash == selected }) { selected = rows.first?.commit.hash }
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
        loaded = true
    }

    // MARK: 提交列表

    private var commitList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(path.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? String(localized: "全部提交"))
                    .font(OMFonts.small).foregroundStyle(OMColors.secondaryText).lineLimit(1).truncationMode(.head)
                Spacer()
                if path == nil { Toggle("所有分支", isOn: $allBranches).toggleStyle(.checkbox).controlSize(.small).font(OMFonts.small) }
                Button { Task { await load() } } label: { Image.om("refresh-cw", size: 12) }
                    .buttonStyle(.plain).accessibilityLabel("刷新历史")
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    let laneWidth = CGFloat(max(1, rows.map(\.laneCount).max() ?? 1)) * 14 + 10
                    ForEach(rows) { row in
                        CommitRow(row: row, laneWidth: path == nil ? laneWidth : 0, isSelected: selected == row.commit.hash)
                            .onTapGesture { selected = row.commit.hash }
                            .accessibilityElement(children: .combine)
                            .accessibilityAddTraits(selected == row.commit.hash ? [.isButton, .isSelected] : .isButton)
                            .omContextMenu {
                                OMMenuItem("拷贝提交哈希", icon: "copy") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(row.commit.hash, forType: .string)
                                }
                            }
                    }
                }
            }
        }
    }

    // MARK: 详情

    @ViewBuilder
    private var detail: some View {
        if let repo, let hash = selected, let row = rows.first(where: { $0.commit.hash == hash }) {
            CommitDetailView(repo: repo, commit: row.commit, workbench: workbench).id(hash)
        } else {
            OMEmptyState { Label("选择一个提交", om: "git-commit-horizontal", size: 28) } description: { Text("右侧会显示它改动的文件。") }
        }
    }
}

/// 提交列表中的一行。
struct CommitRow: View {
    let row: GitGraphRow
    let laneWidth: CGFloat
    let isSelected: Bool
    /// 紧凑模式(右栏图谱分区):隐藏日期与短哈希,避免窄栏溢出
    var compact = false
    static let height: CGFloat = 26

    var body: some View {
        HStack(spacing: 6) {
            if laneWidth > 0 {
                GraphCanvas(row: row).frame(width: laneWidth, height: Self.height)
            }
            Text(row.commit.subject)
                .font(OMFonts.small)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(2)
            ForEach(row.commit.refs.prefix(3), id: \.self) { ref in
                Text(ref.replacingOccurrences(of: "HEAD -> ", with: ""))
                    .font(OMFonts.caption)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(refColor(ref).opacity(0.18), in: OMPillShape())
                    .foregroundStyle(refColor(ref))
                    .lineLimit(1)
                    .layoutPriority(1)
            }
            Spacer(minLength: 6)
            if !compact {
                Text(row.commit.date, format: .relative(presentation: .numeric, unitsStyle: .abbreviated))
                    .font(OMFonts.caption).foregroundStyle(OMColors.tertiaryText).lineLimit(1)
                Text(row.commit.shortHash).font(OMFonts.monoSmall).foregroundStyle(OMColors.secondaryText).lineLimit(1)
            }
        }
        .padding(.leading, laneWidth > 0 ? 0 : 12)
        .padding(.trailing, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Self.height)
        .background(isSelected ? OMColors.selectedFill : .clear)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.commit.shortHash) \(row.commit.subject) \(row.commit.author)")
    }

    private func refColor(_ ref: String) -> Color {
        if ref.hasPrefix("tag:") { return OMColors.warning }
        if ref.hasPrefix("HEAD") { return OMColors.accent }
        if ref.contains("/") { return OMColors.accent2 }
        return OMColors.success
    }
}

/// 一行内的泳道线与提交点。
struct GraphCanvas: View {
    let row: GitGraphRow

    var body: some View {
        Canvas { context, size in
            let h = size.height, mid = h / 2
            func x(_ column: Int) -> CGFloat { 10 + CGFloat(column) * 14 }
            func color(_ index: Int) -> Color { laneColors[abs(index) % laneColors.count] }
            func line(_ from: CGPoint, _ to: CGPoint, _ tint: Color) {
                var path = Path()
                path.move(to: from)
                if from.x == to.x {
                    path.addLine(to: to)
                } else {
                    path.addCurve(to: to, control1: CGPoint(x: from.x, y: (from.y + to.y) / 2), control2: CGPoint(x: to.x, y: (from.y + to.y) / 2))
                }
                context.stroke(path, with: .color(tint), lineWidth: 1.6)
            }
            // 穿过本行的泳道
            for (index, lane) in row.top.enumerated() {
                guard let lane else { continue }
                if row.incoming.contains(index) {
                    line(CGPoint(x: x(index), y: 0), CGPoint(x: x(row.column), y: mid), color(lane.color))
                } else if index < row.bottom.count, row.bottom[index]?.hash == lane.hash {
                    line(CGPoint(x: x(index), y: 0), CGPoint(x: x(index), y: h), color(lane.color))
                }
            }
            // 向下分出的线(各父提交)
            for column in row.outgoing where column < row.bottom.count {
                let tint = row.bottom[column].map { color($0.color) } ?? color(row.color)
                line(CGPoint(x: x(row.column), y: mid), CGPoint(x: x(column), y: h), tint)
            }
            let center = CGPoint(x: x(row.column), y: mid)
            let dot = Path(ellipseIn: CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8))
            context.fill(dot, with: .color(color(row.color)))
            if row.commit.isMerge {
                context.stroke(Path(ellipseIn: CGRect(x: center.x - 5.5, y: center.y - 5.5, width: 11, height: 11)), with: .color(color(row.color)), lineWidth: 1)
            }
        }
    }
}

/// 所选提交的详情:提交信息、文件列表与所选文件的差异。
private struct CommitDetailView: View {
    let repo: GitRepository
    let commit: GitCommit
    let workbench: WorkbenchModel
    @State private var files: [GitFileChange] = []
    @State private var selectedFile: String?
    @State private var diff: FileDiff?
    @State private var binary = false
    @AppStorage("diff.sideBySide") private var sideBySide = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(commit.subject).font(OMFonts.small.weight(.medium)).textSelection(.enabled)
                HStack(spacing: 8) {
                    Text(commit.author)
                    Text(commit.date, format: .dateTime.year().month().day().hour().minute())
                    Text(commit.shortHash).font(OMFonts.monoSmall)
                    if commit.isMerge { OMTag(String(localized: "合并"), tint: OMColors.accent2) }
                }
                .font(OMFonts.caption).foregroundStyle(OMColors.secondaryText)
            }
            .padding(12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(files) { file in
                        HStack(spacing: 6) {
                            Text(file.staged?.badge ?? "").font(OMFonts.caption.weight(.medium)).foregroundStyle(color(file.staged)).frame(width: 14)
                            Text(file.path).font(OMFonts.small).lineLimit(1).truncationMode(.head)
                            Spacer()
                        }
                        .padding(.horizontal, 12).padding(.vertical, 3)
                        .background(selectedFile == file.path ? OMColors.selectedFill : .clear)
                        .contentShape(Rectangle())
                        .onTapGesture { selectedFile = file.path }
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(selectedFile == file.path ? [.isButton, .isSelected] : .isButton)
                        .omContextMenu {
                            OMMenuItem("在编辑器中打开当前版本", icon: "file-text") {
                                workbench.openFile(repo.root.path + "/" + file.path, preview: false)
                            }
                        }
                    }
                    if let diff {
                        Divider().padding(.vertical, 6)
                        OMCompactSegmented(
                            options: [(value: true, title: "并排"), (value: false, title: "统一")],
                            selection: $sideBySide,
                            accessibilityName: String(localized: "Diff 显示模式")
                        )
                        .padding(.horizontal, 12)
                        Group {
                            if sideBySide { SideBySideDiffView(diff: diff) } else { DiffView(diff: diff) }
                        }
                        .padding(12)
                    } else if binary {
                        Text("二进制文件,不显示差异。").font(OMFonts.small).foregroundStyle(OMColors.secondaryText).padding(12)
                    }
                }
            }
        }
        .task { await loadFiles() }
        .task(id: selectedFile) { await loadDiff() }
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
        selectedFile = files.first?.path
    }

    private func loadDiff() async {
        guard let selectedFile else { diff = nil; return }
        do {
            let result = try await repo.fileDiff(path: selectedFile, commit: commit.hash)
            diff = result
            binary = result == nil
        } catch {
            diff = nil
            binary = false
        }
    }
}
