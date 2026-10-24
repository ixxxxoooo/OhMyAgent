// @author ixxxxoooo
// Git 文件差异标签:当 Agent 没有该文件的改动记录时,直接展示工作区与 HEAD(或暂存区)的差异。

import DesignSystem
import DiffKit
import EditorKit
import GitKit
import IconKit
import SwiftUI
import WorkbenchKit

struct GitFileDiffView: View {
    let workbench: WorkbenchModel
    /// 文件绝对路径
    let path: String
    /// 内嵌在文件标签里(对比 HEAD):隐藏「在编辑器中打开」
    var embedded = false
    @AppStorage("diff.sideBySide") private var sideBySide = true
    @Environment(\.tabIsActive) private var isActive
    /// 初始范围;调试钩子 `OMA_DIFF_SCOPE=unstaged|staged|main` 可预置。
    @State private var scope: GitDiffScope = {
        switch ProcessInfo.processInfo.environment["OMA_DIFF_SCOPE"] {
        case "unstaged": return .unstaged
        case "staged": return .staged
        case "main": return .mainBranch
        default: return .workingTree
        }
    }()
    @State private var result: Loaded = .loading
    /// 当前定位的差异块下标(上一处/下一处导航)
    @State private var currentHunk = 0
    /// 最近一次块级操作的错误提示
    @State private var actionError: String?
    @State private var repository: GitRepository?
    @State private var relativePath: String?

    /// 加载结果。
    enum Loaded {
        case loading, notRepository, binary
        case diff(FileDiff)
        case failed(String)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: "\(path)#\(scopeKey)#\(isActive)") {
            // 保存/暂存后差异自动更新;后台标签暂停。工作区内由文件与 Git 状态事件驱动(空闲零开销),工作区外低频轮询
            guard isActive else { return }
            await load()
            // 收到事件后再等 0.3 秒合并连续写入(编译、批量改写),期间的新信号折叠为一次重算
            await WorkspaceWatchCenter.shared.follow(path, poll: .seconds(3), debounce: .milliseconds(300)) { await load() }
        }
    }

    private var scopeKey: String {
        switch scope {
        case .workingTree: return "all"
        case .staged: return "staged"
        case .unstaged: return "unstaged"
        case .mainBranch: return "main"
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text((path as NSString).abbreviatingWithTildeInPath).font(OMFonts.small).foregroundStyle(OMColors.secondaryText).lineLimit(1).truncationMode(.head)
            if case .diff(let diff) = result {
                Text("+\(diff.added)").foregroundStyle(OMColors.diffAdded)
                Text("−\(diff.removed)").foregroundStyle(OMColors.diffRemoved)
            }
            Spacer()
            OMCompactSegmented(
                options: [(value: GitDiffScope.workingTree, title: "全部"), (value: .staged, title: "已暂存"), (value: .unstaged, title: "未暂存"), (value: .mainBranch, title: "主分支")],
                selection: $scope,
                accessibilityName: String(localized: "Diff 范围")
            )
            // 与上一组之间留出间距,避免两组控件挤成一条
            Spacer().frame(width: 8)
            OMCompactSegmented(
                options: [(value: true, title: "并排"), (value: false, title: "统一")],
                selection: $sideBySide,
                accessibilityName: String(localized: "Diff 显示模式")
            )
            hunkNavigator
            if !embedded {
                Button("在编辑器中打开") { workbench.openFile(path, preview: false) }
                    .controlSize(.small)
            }
        }
        .font(OMFonts.small)
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    /// 上一处/下一处差异(⌥F5 / ⇧⌥F5)。
    @ViewBuilder
    private var hunkNavigator: some View {
        if case .diff(let diff) = result, !diff.hunks.isEmpty {
            HStack(spacing: 2) {
                Button { moveHunk(-1, count: diff.hunks.count) } label: { Image.om("chevron-up", size: 12).frame(width: 22, height: 20) }
                    .keyboardShortcut(Self.f5, modifiers: [.option, .shift])
                    .omTooltip("上一处差异 (⇧⌥F5)")
                    .accessibilityLabel("上一处差异")
                Text("\(min(currentHunk, diff.hunks.count - 1) + 1)/\(diff.hunks.count)")
                    .font(OMFonts.caption.monospacedDigit()).foregroundStyle(OMColors.secondaryText)
                Button { moveHunk(1, count: diff.hunks.count) } label: { Image.om("chevron-down", size: 12).frame(width: 22, height: 20) }
                    .keyboardShortcut(Self.f5, modifiers: [.option])
                    .omTooltip("下一处差异 (⌥F5)")
                    .accessibilityLabel("下一处差异")
            }
            .buttonStyle(.plain)
        }
    }

    /// F5 功能键。
    private static let f5 = KeyEquivalent(Character(UnicodeScalar(UInt32(NSF5FunctionKey)) ?? " "))

    private func moveHunk(_ delta: Int, count: Int) {
        guard count > 0 else { return }
        currentHunk = ((currentHunk + delta) % count + count) % count
    }

    /// 块级操作:仅「未暂存」与「已暂存」范围(其基线与索引一致)支持。
    private func hunkActions(for diff: FileDiff) -> [DiffHunkAction] {
        switch scope {
        case .workingTree, .mainBranch: return []
        case .unstaged:
            return [
                DiffHunkAction(title: String(localized: "暂存此块")) { id in apply(.stage, diff: diff, hunk: id) },
                DiffHunkAction(title: String(localized: "放弃此块")) { id in
                    if GitDialogs.confirmDestructive(title: String(localized: "放弃这一块的修改?"), message: String(localized: "此操作不可撤销。"), button: String(localized: "放弃")) {
                        apply(.discard, diff: diff, hunk: id)
                    }
                },
            ]
        case .staged:
            return [DiffHunkAction(title: String(localized: "取消暂存此块")) { id in apply(.unstage, diff: diff, hunk: id) }]
        }
    }

    private func apply(_ action: GitHunkAction, diff: FileDiff, hunk: Int) {
        guard let repository, let relativePath else { return }
        Task {
            do {
                try await repository.applyHunk(action, path: relativePath, diff: diff, hunkID: hunk)
                actionError = nil
                await load()
            } catch {
                actionError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch result {
        case .loading:
            OMSpinner(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        case .notRepository:
            OMEmptyState {
                Label("没有这个文件的改动记录", om: "file-diff", size: 28)
            } description: {
                Text("文件不在 Git 仓库中,Agent 也没有修改过它。")
            }
        case .binary:
            OMEmptyState { Label("二进制文件", om: "file", size: 28) } description: { Text("不显示二进制文件的差异。") }
        case .failed(let message):
            OMEmptyState { Label("无法计算差异", om: "triangle-alert", size: 28) } description: { Text(message) }
        case .diff(let diff):
            if diff.isEmpty {
                OMEmptyState { Label("没有差异", om: "check", size: 28) } description: { Text("这个范围内文件与对比基线相同。") }
            } else {
                VStack(spacing: 0) {
                    if let actionError {
                        Text(actionError).font(OMFonts.small).foregroundStyle(OMColors.danger)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.vertical, 6)
                    }
                    nativeDiff(diff)
                }
            }
        }
    }

    /// 原生 Diff 编辑器(native2 引擎):并排/内联、字符级高亮、折叠未改动区、块头条操作。
    private func nativeDiff(_ diff: FileDiff) -> some View {
        let hunkID = diff.hunks.indices.contains(currentHunk) ? diff.hunks[currentHunk].id : nil
        return NativeDiffEditor(
            old: diff.oldLines.joined(separator: "\n") + (diff.oldTrailingNewline ? "\n" : ""),
            new: diff.newLines.joined(separator: "\n") + (diff.newTrailingNewline ? "\n" : ""),
            diff: diff,
            layoutMode: sideBySide ? .sideBySide : .inline,
            language: SyntaxLanguage.detect(path: path),
            fileName: path,
            actions: hunkActions(for: diff).map { action in NativeDiffAction(title: action.title, perform: action.perform) },
            targetHunk: hunkID
        )
    }

    /// 加载差异。仓库定位只做一次(轮询时复用);结果与当前展示相同时不重新赋值,避免每 2 秒重建整页差异视图。
    private func load() async {
        if repository == nil || relativePath == nil {
            guard let repo = await GitRepository.discover(from: path) else {
                result = .notRepository
                return
            }
            guard let relative = repo.relativePath(of: path) else { result = .notRepository; return }
            repository = repo
            relativePath = relative
        }
        guard let repo = repository, let relative = relativePath else { return }
        do {
            if let diff = try await repo.fileDiff(path: relative, scope: scope) {
                if case .diff(let shown) = result, shown.sameContent(as: diff) { return }
                result = .diff(diff)
            } else {
                result = .binary
            }
        } catch {
            result = .failed((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
    }
}

private extension FileDiff {
    /// 两份差异的内容是否一致(新旧文本逐行相同)。
    func sameContent(as other: FileDiff) -> Bool {
        added == other.added && removed == other.removed && oldLines == other.oldLines && newLines == other.newLines
    }
}
