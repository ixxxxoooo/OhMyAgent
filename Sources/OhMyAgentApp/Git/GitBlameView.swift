// @author ixxxxoooo
// Git Blame 标签:逐行显示最后修改该行的提交、作者与日期;同一提交的连续行只在首行显示信息。

import AppKit
import DesignSystem
import GitKit
import IconKit
import SwiftUI
import WorkbenchKit

struct GitBlameTabView: View {
    let workbench: WorkbenchModel
    /// 文件绝对路径
    let path: String
    @State private var lines: [GitBlameLine] = []
    /// 每行所属提交分组的底色(相邻分组交替),加载时一次算好
    @State private var bands: [Bool] = []
    @State private var phase: Phase = .loading

    private enum Phase: Equatable { case loading, notRepository, failed(String), ready }

    var body: some View {
        switch phase {
        case .loading:
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                .task { await load() }
        case .notRepository:
            ContentUnavailableView { Label("不是 Git 仓库", om: "git-branch", size: 28) } description: { Text("文件不在 Git 仓库中,或尚未提交。") }
        case .failed(let message):
            ContentUnavailableView { Label("无法追溯", om: "triangle-alert", size: 28) } description: { Text(message) }
        case .ready:
            VStack(spacing: 0) {
                HStack {
                    Text((path as NSString).abbreviatingWithTildeInPath).font(OMFonts.small).foregroundStyle(OMColors.secondaryText).lineLimit(1).truncationMode(.head)
                    Spacer()
                    Button("在编辑器中打开") { workbench.openFile(path, preview: false) }.controlSize(.small)
                }
                .padding(.horizontal, 14).padding(.vertical, 6)
                Divider()
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                            BlameLineRow(line: line, showsInfo: index == 0 || lines[index - 1].hash != line.hash, band: bands.indices.contains(index) && bands[index])
                        }
                    }
                }
            }
        }
    }

    private func load() async {
        guard let repo = await GitRepository.discover(from: path), let relative = repo.relativePath(of: path) else {
            phase = .notRepository
            return
        }
        do {
            lines = try await repo.blame(path: relative)
            var flag = false
            bands = lines.enumerated().map { index, line in
                if index > 0, lines[index - 1].hash != line.hash { flag.toggle() }
                return flag
            }
            phase = lines.isEmpty ? .notRepository : .ready
        } catch {
            phase = .failed((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
    }
}

private extension GitBlameLine {
    /// 显示用文本:TAB 展开为 4 个空格(否则 TAB 在单行 Text 里宽度不定、列错位),超长行截断(压缩过的单行脚本会拖垮布局)。
    var displayText: String {
        let expanded = text.replacingOccurrences(of: "\t", with: "    ")
        let limit = 1200
        if expanded.isEmpty { return " " }
        return expanded.count > limit ? String(expanded.prefix(limit)) + "…" : expanded
    }
}

private struct BlameLineRow: View {
    let line: GitBlameLine
    let showsInfo: Bool
    let band: Bool

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                if showsInfo {
                    Text(line.isUncommitted ? String(localized: "未提交") : String(line.hash.prefix(7))).font(OMFonts.monoSmall).foregroundStyle(OMColors.accent)
                    Text(line.author).lineLimit(1)
                    Spacer(minLength: 0)
                    Text(line.date, format: .dateTime.year().month().day()).foregroundStyle(OMColors.tertiaryText)
                } else {
                    Spacer(minLength: 0)
                }
            }
            .font(OMFonts.caption)
            .frame(width: 250, alignment: .leading)
            .padding(.horizontal, 8)
            Text("\(line.lineNumber)").font(OMFonts.monoSmall).foregroundStyle(OMColors.tertiaryText).frame(width: 40, alignment: .trailing)
            Text(line.displayText).font(OMFonts.monoSmall).lineLimit(1).padding(.leading, 10).fixedSize(horizontal: true, vertical: false)
        }
        .frame(height: 18, alignment: .leading)
        .clipped()
        .background(band ? OMColors.subtleFill : .clear)
        .help(line.summary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("第 \(line.lineNumber) 行 \(line.author) \(line.summary) \(line.text)")
    }
}
