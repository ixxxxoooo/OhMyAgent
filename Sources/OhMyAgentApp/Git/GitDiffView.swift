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
    @AppStorage("diff.sideBySide") private var sideBySide = true
    @Environment(\.tabIsActive) private var isActive
    @State private var scope: GitDiffScope = .workingTree
    @State private var result: Loaded = .loading

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
            Picker("范围", selection: $scope) {
                Text("全部").tag(GitDiffScope.workingTree)
                Text("已暂存").tag(GitDiffScope.staged)
                Text("未暂存").tag(GitDiffScope.unstaged)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 170)
            .accessibilityLabel("Diff 范围")
            Picker("显示模式", selection: $sideBySide) {
                Text("并排").tag(true)
                Text("统一").tag(false)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 100)
            .accessibilityLabel("Diff 显示模式")
            Button("在编辑器中打开") { workbench.openFile(path, preview: false) }
                .controlSize(.small)
        }
        .font(OMFonts.small)
        .padding(.horizontal, 14).padding(.vertical, 8)
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
                ScrollView {
                    Group {
                        if sideBySide { SideBySideDiffView(diff: diff) } else { DiffView(diff: diff) }
                    }
                    .padding(14)
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
