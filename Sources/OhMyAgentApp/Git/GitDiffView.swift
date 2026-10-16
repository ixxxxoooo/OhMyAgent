// @author ixxxxoooo
// Git 文件差异标签:当 Agent 没有该文件的改动记录时,直接展示工作区与 HEAD(或暂存区)的差异。

import DesignSystem
import DiffKit
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
    @State private var scope: GitDiffScope = .workingTree
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
            // 打开期间每 2 秒重算一次,保存/暂存后差异自动更新;后台标签暂停
            guard isActive else { return }
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private var scopeKey: String {
        switch scope {
        case .workingTree: return "all"
        case .staged: return "staged"
        case .unstaged: return "unstaged"
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
                options: [(value: GitDiffScope.workingTree, title: "全部"), (value: .staged, title: "已暂存"), (value: .unstaged, title: "未暂存")],
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
                    .help("上一处差异 (⇧⌥F5)")
                    .accessibilityLabel("上一处差异")
                Text("\(min(currentHunk, diff.hunks.count - 1) + 1)/\(diff.hunks.count)")
                    .font(OMFonts.caption.monospacedDigit()).foregroundStyle(OMColors.secondaryText)
                Button { moveHunk(1, count: diff.hunks.count) } label: { Image.om("chevron-down", size: 12).frame(width: 22, height: 20) }
                    .keyboardShortcut(Self.f5, modifiers: [.option])
                    .help("下一处差异 (⌥F5)")
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
        case .workingTree: return []
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
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        case .notRepository:
            ContentUnavailableView {
                Label("没有这个文件的改动记录", om: "file-diff", size: 28)
            } description: {
                Text("文件不在 Git 仓库中,Agent 也没有修改过它。")
            }
        case .binary:
            ContentUnavailableView { Label("二进制文件", om: "file", size: 28) } description: { Text("不显示二进制文件的差异。") }
        case .failed(let message):
            ContentUnavailableView { Label("无法计算差异", om: "triangle-alert", size: 28) } description: { Text(message) }
        case .diff(let diff):
            if diff.isEmpty {
                ContentUnavailableView { Label("没有差异", om: "check", size: 28) } description: { Text("这个范围内文件与对比基线相同。") }
            } else {
                VStack(spacing: 0) {
                    if let actionError {
                        Text(actionError).font(OMFonts.small).foregroundStyle(OMColors.danger)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.vertical, 6)
                    }
                    ScrollViewReader { proxy in
                        ScrollView {
                            Group {
                                if sideBySide { SideBySideDiffView(diff: diff, extraActions: hunkActions(for: diff)) }
                                else { DiffView(diff: diff, extraActions: hunkActions(for: diff)) }
                            }
                            .padding(14)
                        }
                        .onChange(of: currentHunk) { _, index in
                            guard diff.hunks.indices.contains(index) else { return }
                            withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(diff.hunks[index].id, anchor: .top) }
                        }
                    }
                }
            }
        }
    }

    private func load() async {
        guard let repo = await GitRepository.discover(from: path) else {
            result = .notRepository
            return
        }
        guard let relative = repo.relativePath(of: path) else { result = .notRepository; return }
        repository = repo
        relativePath = relative
        do {
            if let diff = try await repo.fileDiff(path: relative, scope: scope) {
                result = .diff(diff)
            } else {
                result = .binary
            }
        } catch {
            result = .failed((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
    }
}
