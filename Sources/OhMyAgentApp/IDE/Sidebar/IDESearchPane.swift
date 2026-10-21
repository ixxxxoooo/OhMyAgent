// @author ixxxxoooo
// IDE 侧栏「搜索」视图:查询/替换输入、大小写/全词/正则开关、包含路径过滤、按文件分组的结果列表;
// 支持替换单条、整文件与全部,并可撤销最近一次替换。

import DesignSystem
import IconKit
import IDEKit
import SwiftUI
import WorkbenchKit

struct IDESearchPane: View {
    let workspace: IDEWorkspace
    @Bindable var model: IDESearchModel
    @FocusState private var focused: Bool?

    var body: some View {
        VStack(spacing: 0) {
            inputs
            if let notice = model.notice { noticeBar(notice) }
            results
        }
        .task(id: workspace.root) { model.root = workspace.root; focused = true }
        .onChange(of: model.focusToken) { focused = true }
    }

    // MARK: 输入区

    private var inputs: some View {
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                Button { model.showsReplace.toggle() } label: { Image.om(model.showsReplace ? "chevron-down" : "chevron-right", size: 12) }
                    .buttonStyle(.omIcon).omTooltip(String(localized: "切换替换")).accessibilityLabel(String(localized: "切换替换"))
                field(String(localized: "搜索"), text: $model.query, focus: true) {
                    toggle("Aa", $model.caseSensitive, String(localized: "区分大小写"))
                    toggle("ab", $model.wholeWord, String(localized: "全词匹配"))
                    toggle(".*", $model.isRegex, String(localized: "正则表达式"))
                }
            }
            if model.showsReplace {
                HStack(spacing: 4) {
                    Color.clear.frame(width: 24, height: 24)
                    field(String(localized: "替换"), text: $model.replacement, focus: false) {
                        Button { model.replaceAll() } label: { Image.om("list-checks", size: 14) }
                            .buttonStyle(.omIcon)
                            .disabled(model.output?.files.isEmpty ?? true)
                            .omTooltip(String(localized: "全部替换"))
                            .accessibilityLabel(String(localized: "全部替换"))
                    }
                }
            }
            HStack(spacing: 4) {
                Color.clear.frame(width: 24, height: 0)
                field(String(localized: "要包含的文件(如 *.swift, Sources/**)"), text: $model.pathFilter, focus: false) { EmptyView() }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
    }

    private func field<Trailing: View>(_ prompt: String, text: Binding<String>, focus: Bool, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 2) {
            TextField(prompt, text: text)
                .textFieldStyle(.plain)
                .font(OMFonts.small)
                .focused($focused, equals: focus)
            trailing()
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(OMColors.surface, in: RoundedRectangle(cornerRadius: OMRadius.control))
        .overlay(RoundedRectangle(cornerRadius: OMRadius.control).strokeBorder(OMColors.hairline, lineWidth: 1))
    }

    private func toggle(_ label: String, _ binding: Binding<Bool>, _ help: String) -> some View {
        Button { binding.wrappedValue.toggle() } label: {
            Text(label).font(OMFonts.custom(11, weight: .medium, design: .monospaced))
                .foregroundStyle(binding.wrappedValue ? OMColors.accentText : OMColors.secondaryText)
                .frame(width: 22, height: 20)
                .background(binding.wrappedValue ? OMColors.selectedFill : Color.clear, in: OMPillShape())
        }
        .buttonStyle(.plain)
        .omTooltip(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(binding.wrappedValue ? .isSelected : [])
    }

    private func noticeBar(_ text: String) -> some View {
        HStack(spacing: 6) {
            Text(text).font(OMFonts.caption).foregroundStyle(OMColors.secondaryText).lineLimit(3)
            Spacer(minLength: 0)
            if model.lastReplace != nil { Button("撤销") { model.undoReplace() }.buttonStyle(.omPlain) }
            Button { model.clearNotice() } label: { Image.om("x", size: 12) }
                .buttonStyle(.omIcon).accessibilityLabel(String(localized: "关闭"))
        }
        .padding(.horizontal, 12).padding(.vertical, 4)
    }

    // MARK: 结果

    @ViewBuilder
    private var results: some View {
        if let error = model.output?.error {
            Text(error).font(OMFonts.small).foregroundStyle(OMColors.danger).padding(12).frame(maxWidth: .infinity, alignment: .leading)
            Spacer()
        } else if let output = model.output {
            if output.files.isEmpty {
                OMEmptyState { Label("没有结果", om: "search", size: 28) } description: { Text("换个关键词或放宽选项再试试。") }
            } else {
                list(output)
            }
        } else if model.isSearching {
            OMSpinner(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            OMEmptyState { Label("在文件中搜索", om: "text-search", size: 28) } description: { Text("输入关键词,在工作区的所有文本文件中查找。") }
        }
    }

    private func list(_ output: SearchOutput) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("\(output.totalHits) 个结果,\(output.files.count) 个文件\(output.truncated ? String(localized: "(已截断)") : "")")
                if model.isSearching { OMSpinner(.mini) }
                Spacer()
            }
            .font(OMFonts.caption).foregroundStyle(OMColors.secondaryText)
            .padding(.horizontal, 12).padding(.vertical, 4)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(output.files) { file in
                        FileHeader(model: model, file: file)
                        if !model.collapsed.contains(file.id) {
                            ForEach(file.hits) { hit in HitRow(workspace: workspace, model: model, hit: hit) }
                        }
                    }
                }
            }
        }
    }
}

/// 文件分组头:折叠、替换整个文件。
private struct FileHeader: View {
    let model: IDESearchModel
    let file: SearchFileResult
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            Image.om(model.collapsed.contains(file.id) ? "chevron-right" : "chevron-down", size: 10)
            OMFileIcon(name: (file.path as NSString).lastPathComponent, size: 14)
            Text((file.path as NSString).lastPathComponent).font(OMFonts.small).lineLimit(1)
            Text((file.path as NSString).deletingLastPathComponent).font(OMFonts.caption).foregroundStyle(OMColors.tertiaryText)
                .lineLimit(1).truncationMode(.head)
            Spacer(minLength: 4)
            if hovering && model.showsReplace {
                Button { model.replace(file: file) } label: { Image.om("list-checks", size: 12) }
                    .buttonStyle(.omIcon).omTooltip(String(localized: "替换此文件中的全部匹配")).accessibilityLabel(String(localized: "替换此文件中的全部匹配"))
            }
            Text("\(file.hits.count)").font(OMFonts.caption).foregroundStyle(OMColors.secondaryText)
        }
        .padding(.horizontal, 12)
        .frame(height: 24)
        .background(hovering ? OMColors.hoverFill : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            if model.collapsed.contains(file.id) { model.collapsed.remove(file.id) } else { model.collapsed.insert(file.id) }
        }
        .accessibilityAddTraits(.isButton)
    }
}

/// 一条命中:行号 + 高亮预览;单击在编辑器里预览打开并定位,悬停时可单条替换。
private struct HitRow: View {
    let workspace: IDEWorkspace
    let model: IDESearchModel
    let hit: SearchHit
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Text(attributed).font(OMFonts.monoSmall).lineLimit(1)
            Spacer(minLength: 4)
            if hovering && model.showsReplace {
                Button { model.replace(hit: hit) } label: { Image.om("pencil", size: 12) }
                    .buttonStyle(.omIcon).omTooltip(String(localized: "替换")).accessibilityLabel(String(localized: "替换"))
            }
        }
        .padding(.leading, 34).padding(.trailing, 12)
        .frame(height: 22)
        .background(hovering ? OMColors.hoverFill : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            guard let root = workspace.root else { return }
            workspace.model.openFile(root + "/" + hit.path, line: hit.line, preview: true)
        }
        .accessibilityLabel("\(hit.path):\(hit.line) \(hit.preview)")
    }

    /// 预览文本,命中范围高亮为强调色。
    private var attributed: AttributedString {
        var text = AttributedString(hit.preview)
        text.foregroundColor = OMColors.secondaryText
        let chars = Array(hit.preview)
        let start = min(max(hit.previewColumn, 0), chars.count)
        let end = min(start + hit.length, chars.count)
        if start < end {
            let lower = text.index(text.startIndex, offsetByCharacters: start)
            let upper = text.index(text.startIndex, offsetByCharacters: end)
            text[lower..<upper].foregroundColor = OMColors.accentText
            text[lower..<upper].backgroundColor = OMColors.selectedFill
        }
        return text
    }
}
