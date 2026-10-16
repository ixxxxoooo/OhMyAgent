// @author ixxxxoooo
// 文件渲染预览:Markdown、Mermaid、图片/SVG、PDF、CSV/TSV。全部原生渲染(无 WebView)。
// 文件标签通过「源码 / 预览」切换在编辑器与渲染结果之间切换,文本修改实时反映到预览。

import AppKit
import DesignSystem
import IconKit
import Observation
import PDFKit
import SwiftUI

/// 可渲染预览的文件类型。
enum FilePreviewKind: Equatable {
    case markdown, mermaid, svg, image, pdf, spreadsheet, csv(delimiter: Character)

    /// 按扩展名识别;不支持预览返回 nil。
    static func of(path: String) -> FilePreviewKind? {
        switch (path as NSString).pathExtension.lowercased() {
        case "md", "markdown", "mdx": return .markdown
        case "mmd", "mermaid": return .mermaid
        case "svg": return .svg
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "tif", "tiff", "bmp", "ico", "icns": return .image
        case "pdf": return .pdf
        case "xlsx", "xlsm": return .spreadsheet
        case "csv": return .csv(delimiter: ",")
        case "tsv": return .csv(delimiter: "\t")
        default: return nil
        }
    }

    /// 是否为二进制文件(不能当文本编辑,只有预览)。
    var isBinary: Bool { self == .image || self == .pdf || self == .spreadsheet }
}

/// 文件标签的显示模式。
enum FileViewMode: String, CaseIterable, Identifiable {
    /// Markdown 就地渲染(Typora 式)
    case live
    case source, preview
    var id: String { rawValue }

    var title: String {
        switch self {
        case .live: return String(localized: "渲染")
        case .source: return String(localized: "源码")
        case .preview: return String(localized: "预览")
        }
    }

    /// 某类型可用的模式(就地渲染只对 Markdown 有意义)。
    static func available(for kind: FilePreviewKind) -> [FileViewMode] {
        kind == .markdown ? [.live, .source, .preview] : [.source, .preview]
    }

    /// 编辑器是否可见(预览模式下隐藏编辑器)。
    var showsEditor: Bool { self != .preview }
}

/// 各文件的显示模式记忆(同一文件再次打开时沿用)。
@MainActor
@Observable
final class FileViewModeStore {
    static let shared = FileViewModeStore()
    private var modes: [String: FileViewMode] = [:]

    /// 取某文件的模式;未设置时 Markdown 默认就地渲染,其余可渲染类型默认预览。
    func mode(for path: String, kind: FilePreviewKind) -> FileViewMode {
        if let stored = modes[path], FileViewMode.available(for: kind).contains(stored) { return stored }
        return kind == .markdown ? .live : .preview
    }

    func set(_ mode: FileViewMode, for path: String) { modes[path] = mode }
}

// MARK: - 预览分发

/// 文本类预览(随编辑实时刷新)。
struct TextPreviewView: View {
    let kind: FilePreviewKind
    let text: String

    var body: some View {
        switch kind {
        case .markdown: MarkdownPreviewView(text: text)
        case .mermaid: MermaidFilePreview(text: text)
        case .svg: SVGPreviewView(text: text)
        case .csv(let delimiter): CSVTableView(text: text, delimiter: delimiter)
        case .image, .pdf, .spreadsheet: EmptyView()
        }
    }
}

/// Markdown 预览:防抖后整段重解析(300KB 约 22ms),标题/列表/表格/代码块(带语法高亮)/Mermaid 原生渲染。
struct MarkdownPreviewView: View {
    let text: String
    @State private var shown: String

    init(text: String) {
        self.text = text
        _shown = State(initialValue: text)
    }

    var body: some View {
        ScrollView {
            MarkdownView(text: shown)
                .frame(maxWidth: 820, alignment: .leading)
                .padding(.horizontal, 28).padding(.vertical, 22)
                .frame(maxWidth: .infinity)
        }
        .background(OMColors.surface)
        .task(id: text) {
            guard text != shown else { return }
            try? await Task.sleep(for: .milliseconds(80))
            if !Task.isCancelled { shown = text }
        }
    }
}

/// `.mmd` 文件预览:整份文件作为 Mermaid 源码。
struct MermaidFilePreview: View {
    let text: String

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            MermaidBlockView(source: text)
                .padding(20)
        }
        .background(OMColors.surface)
    }
}

/// SVG 预览:系统矢量图原生渲染。
struct SVGPreviewView: View {
    let text: String

    var body: some View {
        if let image = NSImage(data: Data(text.utf8)), image.size.width > 0 {
            ImageCanvas(image: image)
        } else {
            ContentUnavailableView {
                Label("无法渲染这个 SVG", om: "image", size: 28)
            } description: {
                Text("文件内容不是有效的 SVG,请在「源码」中检查。")
            }
        }
    }
}

/// 图片画布:默认适应窗口,点击切换实际大小。
struct ImageCanvas: View {
    let image: NSImage
    @State private var actualSize = false

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if actualSize {
                    ScrollView([.horizontal, .vertical]) {
                        Image(nsImage: image).padding(16)
                    }
                } else {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(16)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(Checkerboard())
            Divider()
            HStack(spacing: 10) {
                Text("\(Int(image.size.width)) × \(Int(image.size.height))")
                    .font(OMFonts.small).foregroundStyle(OMColors.secondaryText)
                Spacer()
                Button(actualSize ? String(localized: "适应窗口") : String(localized: "实际大小")) { actualSize.toggle() }
                    .controlSize(.small)
            }
            .padding(.horizontal, 12).padding(.vertical, 5)
        }
    }
}

/// 透明背景棋盘格。
private struct Checkerboard: View {
    var body: some View {
        Canvas { context, size in
            let cell: CGFloat = 10
            let columns = Int(size.width / cell) + 1
            let rows = Int(size.height / cell) + 1
            for row in 0..<rows {
                for column in 0..<columns where (row + column) % 2 == 0 {
                    context.fill(Path(CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell, width: cell, height: cell)), with: .color(Color.primary.opacity(0.05)))
                }
            }
        }
        .background(OMColors.surface)
    }
}

/// 二进制文件(图片/PDF)标签:只有预览,没有文本编辑。
struct BinaryPreviewTab: View {
    let path: String
    let kind: FilePreviewKind
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        Group {
            switch kind {
            case .pdf:
                PDFPreviewView(url: URL(fileURLWithPath: path))
            case .spreadsheet:
                SpreadsheetTabView(path: path)
            default:
                if let image {
                    ImageCanvas(image: image)
                } else if failed {
                    ContentUnavailableView {
                        Label("无法打开图片", om: "image", size: 28)
                    } description: {
                        Text("文件已损坏或格式不受支持。")
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .task(id: path) {
            guard kind == .image else { return }
            let target = path
            let loaded = await Task.detached(priority: .userInitiated) { NSImage(contentsOfFile: target) }.value
            if let loaded { image = loaded } else { failed = true }
        }
    }
}

/// PDF 预览(PDFKit)。
struct PDFPreviewView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.document = PDFDocument(url: url)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document?.documentURL != url { view.document = PDFDocument(url: url) }
    }
}

// MARK: - CSV

/// CSV/TSV 解析器(支持引号、转义引号、引号内换行)。
enum CSVParser {
    /// - Parameters:
    ///   - text: 文本
    ///   - delimiter: 分隔符
    ///   - maxRows: 最多解析的行数(超出截断)
    /// - Returns: 行列二维数组
    static func parse(_ text: String, delimiter: Character, maxRows: Int = 5000) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = text.makeIterator()
        var pending: Character?

        func endField() { row.append(field); field = "" }
        func endRow() {
            endField()
            if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
            row = []
        }

        while rows.count < maxRows {
            let next = pending ?? iterator.next()
            pending = nil
            guard let ch = next else { break }
            if inQuotes {
                if ch == "\"" {
                    if let following = iterator.next() {
                        if following == "\"" { field.append("\"") } else { inQuotes = false; pending = following }
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(ch)
                }
            } else if ch == "\"" && field.isEmpty {
                inQuotes = true
            } else if ch == delimiter {
                endField()
            } else if ch == "\n" || ch == "\r\n" {
                endRow()
            } else if ch == "\r" {
                continue
            } else {
                field.append(ch)
            }
        }
        if rows.count < maxRows, !field.isEmpty || !row.isEmpty { endRow() }
        return rows
    }
}

/// 表格预览:首行作表头,列宽按内容估算,大表格懒加载。
struct CSVTableView: View {
    let text: String
    let delimiter: Character
    @State private var rows: [[String]] = []

    var body: some View {
        Group {
            if rows.isEmpty {
                ContentUnavailableView { Label("表格为空", om: "columns-2", size: 28) } description: { Text("文件里没有可显示的行。") }
            } else {
                let columns = rows.map(\.count).max() ?? 0
                let widths = columnWidths(columns: columns)
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        Section {
                            ForEach(Array(rows.dropFirst().enumerated()), id: \.offset) { index, row in
                                rowView(row, widths: widths, header: false)
                                    .background(index % 2 == 1 ? Color.primary.opacity(0.035) : Color.clear)
                            }
                        } header: {
                            rowView(rows[0], widths: widths, header: true)
                                .background(OMColors.card)
                        }
                    }
                    .padding(12)
                }
            }
        }
        .background(OMColors.surface)
        .task(id: text) {
            let source = text
            let separator = delimiter
            rows = await Task.detached(priority: .userInitiated) { CSVParser.parse(source, delimiter: separator) }.value
        }
    }

    private func columnWidths(columns: Int) -> [CGFloat] {
        (0..<columns).map { column in
            let longest = rows.prefix(200).map { $0.indices.contains(column) ? $0[column].count : 0 }.max() ?? 0
            return min(max(CGFloat(longest) * 7.5 + 20, 60), 360)
        }
    }

    private func rowView(_ row: [String], widths: [CGFloat], header: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(widths.enumerated()), id: \.offset) { column, width in
                Text(row.indices.contains(column) ? row[column] : "")
                    .font(header ? OMFonts.small.weight(.semibold) : OMFonts.small)
                    .lineLimit(3)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .frame(width: width, alignment: .leading)
                    .overlay(alignment: .trailing) { Rectangle().fill(OMColors.hairline.opacity(0.5)).frame(width: 0.5) }
            }
        }
        .overlay(alignment: .bottom) { Rectangle().fill(OMColors.hairline.opacity(0.5)).frame(height: 0.5) }
    }
}
