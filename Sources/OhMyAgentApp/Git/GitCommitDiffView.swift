// @author ixxxxoooo
// 提交文件差异标签:在中间栏并排(或内联)对比某个提交里单个文件相对其父提交的改动。

import DesignSystem
import DiffKit
import EditorKit
import GitKit
import SwiftUI

struct GitCommitDiffTabView: View {
    /// 仓库根目录
    let root: String
    /// 提交哈希
    let commit: String
    /// 仓库内相对路径
    let path: String
    @AppStorage("diff.sideBySide") private var sideBySide = true
    @State private var result: Loaded = .loading

    private enum Loaded {
        case loading, binary
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
        .task { await load() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(path).font(OMFonts.small).foregroundStyle(OMColors.secondaryText).lineLimit(1).truncationMode(.head)
            Text(String(commit.prefix(7))).font(OMFonts.monoSmall).foregroundStyle(OMColors.tertiaryText)
            if case .diff(let diff) = result {
                Text("+\(diff.added)").foregroundStyle(OMColors.diffAdded)
                Text("−\(diff.removed)").foregroundStyle(OMColors.diffRemoved)
            }
            Spacer()
            OMCompactSegmented(
                options: [(value: true, title: "并排"), (value: false, title: "统一")],
                selection: $sideBySide,
                accessibilityName: String(localized: "Diff 显示模式")
            )
        }
        .font(OMFonts.small)
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        switch result {
        case .loading:
            OMSpinner(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        case .binary:
            OMEmptyState { Label("二进制文件", om: "file", size: 28) } description: { Text("不显示二进制文件的差异。") }
        case .failed(let message):
            OMEmptyState { Label("无法计算差异", om: "triangle-alert", size: 28) } description: { Text(message) }
        case .diff(let diff):
            if diff.isEmpty {
                OMEmptyState { Label("没有差异", om: "check", size: 28) } description: { Text("这个提交没有改动该文件内容。") }
            } else {
                NativeDiffEditor(
                    old: diff.oldLines.joined(separator: "\n") + (diff.oldTrailingNewline ? "\n" : ""),
                    new: diff.newLines.joined(separator: "\n") + (diff.newTrailingNewline ? "\n" : ""),
                    diff: diff,
                    layoutMode: sideBySide ? .sideBySide : .inline,
                    language: SyntaxLanguage.detect(path: path),
                    fileName: path,
                    actions: [],
                    targetHunk: nil
                )
            }
        }
    }

    /// 读取该提交的文件差异。
    private func load() async {
        guard let repo = await GitRepository.discover(from: root) else { result = .failed(String(localized: "不是 Git 仓库")); return }
        do {
            if let diff = try await repo.fileDiff(path: path, commit: commit) { result = .diff(diff) } else { result = .binary }
        } catch {
            result = .failed((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
    }
}
