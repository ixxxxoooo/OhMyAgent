// @author ixxxxoooo
// 全局搜索面板:关键词、区分大小写/整词/正则、路径过滤;结果按文件分组,点击跳转到行。

import DesignSystem
import IconKit
import SwiftUI
import WorkbenchKit

struct SearchPaneView: View {
    let workbench: WorkbenchModel
    @Bindable private var model = SearchModel.shared
    @FocusState private var focused: Bool
    @State private var collapsed: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                HStack(spacing: 4) {
                    TextField("搜索", text: $model.query)
                        .textFieldStyle(.roundedBorder)
                        .focused($focused)
                        .onSubmit { model.schedule() }
                    toggle("Aa", $model.caseSensitive, help: "区分大小写")
                    toggle("W", $model.wholeWord, help: "全字匹配")
                    toggle(".*", $model.isRegex, help: "使用正则表达式")
                }
                TextField("限定路径(包含该文本的文件)", text: $model.pathFilter)
                    .textFieldStyle(.roundedBorder)
                    .font(OMFonts.small)
            }
            .padding(10)
            Divider()
            results
        }
        .onAppear { model.root = workbench.selectedProjectID; focused = true }
        .onChange(of: workbench.selectedProjectID) { _, new in model.root = new; model.schedule() }
        .onChange(of: model.focusToken) { focused = true }
    }

    private func toggle(_ label: String, _ binding: Binding<Bool>, help: LocalizedStringKey) -> some View {
        Toggle(isOn: binding) { Text(label).font(OMFonts.custom(11, weight: .medium, design: .monospaced)) }
            .toggleStyle(.button)
            .controlSize(.small)
            .help(help)
            .accessibilityLabel(Text(help))
    }

    @ViewBuilder
    private var results: some View {
        if workbench.selectedProject == nil {
            placeholder("folder", "没有项目", "添加一个项目后可搜索其中的文件。")
        } else if let error = model.output?.error {
            errorView(error)
        } else if let output = model.output {
            if output.files.isEmpty {
                placeholder("search", "没有结果", "换个关键词或放宽选项再试试。")
            } else {
                resultList(output)
            }
        } else if model.isSearching {
            OMSpinner(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            placeholder("text-search", "在文件中搜索", "输入关键词,在当前项目的所有文本文件中查找。")
        }
    }

    private func placeholder(_ icon: String, _ title: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
        OMEmptyState {
            Label(title, om: icon, size: 28)
        } description: {
            Text(detail)
        }
    }

    private func errorView(_ message: String) -> some View {
        VStack {
            Text(message).font(OMFonts.small).foregroundStyle(OMColors.diffRemoved).padding(12).frame(maxWidth: .infinity, alignment: .leading)
            Spacer()
        }
    }

    private func resultList(_ output: SearchOutput) -> some View {
        VStack(spacing: 0) {
            summary(output)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(output.files) { file in
                        fileHeader(file)
                        if !collapsed.contains(file.id) {
                            ForEach(file.hits) { hit in HitRow(hit: hit, workbench: workbench) }
                        }
                    }
                }
            }
        }
    }

    private func summary(_ output: SearchOutput) -> some View {
        HStack(spacing: 6) {
            Text("\(output.totalHits) 个结果,\(output.files.count) 个文件\(output.truncated ? String(localized: "(已截断)") : "")")
            if model.isSearching { OMSpinner(.mini) }
            Spacer()
        }
        .font(OMFonts.caption).foregroundStyle(OMColors.secondaryText)
        .padding(.horizontal, 10).padding(.vertical, 4)
    }

    private func fileHeader(_ file: SearchFileResult) -> some View {
        Button {
            if collapsed.contains(file.id) { collapsed.remove(file.id) } else { collapsed.insert(file.id) }
        } label: {
            HStack(spacing: 4) {
                Image.om(collapsed.contains(file.id) ? "chevron-right" : "chevron-down", size: 10)
                OMFileIcon(name: (file.path as NSString).lastPathComponent, size: 14)
                Text((file.path as NSString).lastPathComponent).font(OMFonts.small.weight(.medium))
                if let root = file.root, root != workbench.selectedProjectID {
                    Text(verbatim: (root as NSString).lastPathComponent).font(OMFonts.caption).foregroundStyle(OMColors.accentText)
                }
                Text((file.path as NSString).deletingLastPathComponent).font(OMFonts.caption).foregroundStyle(OMColors.secondaryText).lineLimit(1).truncationMode(.head)
                Spacer()
                Text("\(file.hits.count)").font(OMFonts.caption).foregroundStyle(OMColors.secondaryText)
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct HitRow: View {
    let hit: SearchHit
    let workbench: WorkbenchModel
    @State private var hovering = false

    var body: some View {
        Button {
            guard let root = hit.root ?? workbench.selectedProjectID else { return }
            workbench.openFile((root as NSString).appendingPathComponent(hit.path), line: hit.line, preview: true)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(hit.line)").font(OMFonts.caption.monospacedDigit()).foregroundStyle(OMColors.secondaryText).frame(width: 30, alignment: .trailing)
                Text(highlighted).font(OMFonts.readingMono).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 2)
            .background(hovering ? OMColors.hoverFill : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    /// 预览文本,命中片段高亮。
    private var highlighted: AttributedString {
        var text = AttributedString(hit.preview)
        let ns = hit.preview as NSString
        let range = NSRange(location: max(0, min(hit.previewColumn, ns.length)), length: max(0, min(hit.length, ns.length - max(0, min(hit.previewColumn, ns.length)))))
        if range.length > 0, let swiftRange = Range(range, in: hit.preview), let lower = AttributedString.Index(swiftRange.lowerBound, within: text), let upper = AttributedString.Index(swiftRange.upperBound, within: text) {
            text[lower..<upper].backgroundColor = OMColors.accent.opacity(0.3)
            text[lower..<upper].font = OMFonts.readingMono.weight(.bold) // ui-lint:allow 搜索命中高亮属于内容强调
        }
        return text
    }
}
