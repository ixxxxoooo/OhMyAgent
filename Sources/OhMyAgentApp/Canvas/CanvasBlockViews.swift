// @author ixxxxoooo
// Canvas 块渲染:把 `CanvasBlock` 画成原生 SwiftUI 视图(标题、Markdown、统计卡、可排序表格、
// Swift Charts 图表、提示框、代码、图片、Mermaid、可折叠分区)。颜色与字号全部走设计令牌。

import AppKit
import CanvasKit
import Charts
import DesignSystem
import IconKit
import SwiftUI

/// 画布正文:块列表的纵向排布(标签页与导出 PNG 共用)。
struct CanvasBodyView: View {
    let document: CanvasDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(Array(document.blocks.enumerated()), id: \.offset) { _, block in
                CanvasBlockView(block: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 单个块。
struct CanvasBlockView: View {
    let block: CanvasBlock

    var body: some View {
        switch block {
        case .heading(let text, let level):
            Text(verbatim: text)
                .font(OMFonts.custom(level == 1 ? 24 : (level == 2 ? 18 : 15), weight: .medium))
                .padding(.top, level == 1 ? 4 : 8)
                .accessibilityAddTraits(.isHeader)
        case .markdown(let text):
            MarkdownView(text: text)
        case .stats(let items):
            CanvasStatsView(items: items)
        case .table(let table):
            CanvasTableView(table: table)
        case .chart(let chart):
            if chart.kind == .candle { CandleChartView(chart: chart) } else { CanvasChartView(chart: chart) }
        case .callout(let tone, let title, let text):
            CanvasCalloutView(tone: tone, title: title, text: text)
        case .code(let language, let text):
            CodeBlockView(language: language, code: text)
        case .image(let source, let caption):
            CanvasImageView(source: source, caption: caption)
        case .mermaid(let source):
            MermaidBlockView(source: source)
        case .section(let title, let collapsed, let blocks):
            CanvasSectionView(title: title, initiallyCollapsed: collapsed, blocks: blocks)
        case .divider:
            Divider().padding(.vertical, 4)
        }
    }
}

// MARK: - 色调

extension CanvasTone {
    /// 色调对应的令牌色。
    var color: Color {
        switch self {
        case .neutral: return OMColors.secondaryText
        case .info: return OMColors.accent
        case .success: return OMColors.success
        case .warning: return OMColors.warning
        case .danger: return OMColors.danger
        }
    }

    /// 提示框图标。
    var icon: String {
        switch self {
        case .neutral, .info: return "info"
        case .success: return "circle-check"
        case .warning: return "triangle-alert"
        case .danger: return "circle-x"
        }
    }
}

// MARK: - 统计卡

private struct CanvasStatsView: View {
    let items: [CanvasStat]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], alignment: .leading, spacing: 10) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: item.label).font(OMFonts.small).foregroundStyle(OMColors.secondaryText).lineLimit(1)
                    Text(verbatim: item.value).font(OMFonts.custom(22, weight: .medium)).lineLimit(1).minimumScaleFactor(0.6)
                    if let delta = item.delta {
                        Text(verbatim: delta).font(OMFonts.caption).foregroundStyle(item.tone == .neutral ? OMColors.tertiaryText : item.tone.color)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .omSolidCard()
                .accessibilityElement(children: .combine)
            }
        }
    }
}

// MARK: - 表格

/// 表格排序状态(纯逻辑,便于测试)。
struct CanvasTableSort: Equatable {
    var column: Int?
    var ascending = true

    /// 点击列头:首次升序,再点降序,第三次取消排序。
    /// - Parameter index: 列序号
    mutating func toggle(_ index: Int) {
        if column != index { column = index; ascending = true }
        else if ascending { ascending = false }
        else { column = nil; ascending = true }
    }

    /// 按当前状态排序行(数值感知、稳定)。
    /// - Parameter rows: 原始行
    func apply(to rows: [[String]]) -> [[String]] {
        guard let column else { return rows }
        let indexed = rows.enumerated().map { ($0.offset, $0.element) }
        let sorted = indexed.sorted { lhs, rhs in
            let a = lhs.1.indices.contains(column) ? lhs.1[column] : ""
            let b = rhs.1.indices.contains(column) ? rhs.1[column] : ""
            let order: ComparisonResult
            if let x = Double(a.replacingOccurrences(of: ",", with: "")), let y = Double(b.replacingOccurrences(of: ",", with: "")) {
                order = x == y ? .orderedSame : (x < y ? .orderedAscending : .orderedDescending)
            } else {
                order = a.localizedStandardCompare(b)
            }
            if order == .orderedSame { return lhs.0 < rhs.0 }
            return ascending ? order == .orderedAscending : order == .orderedDescending
        }
        return sorted.map(\.1)
    }
}

private struct CanvasTableView: View {
    let table: CanvasTable
    @State private var sort = CanvasTableSort()
    @State private var showAll = false
    private static let previewRows = 200

    var body: some View {
        let sorted = sort.apply(to: table.rows)
        let visible = showAll ? sorted : Array(sorted.prefix(Self.previewRows))
        VStack(alignment: .leading, spacing: 6) {
            if let title = table.title, !title.isEmpty { Text(verbatim: title).font(OMFonts.body.weight(.medium)) }
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                    GridRow {
                        ForEach(Array(table.columns.enumerated()), id: \.offset) { index, name in header(name, index) }
                    }
                    Divider().gridCellUnsizedAxes(.horizontal)
                    ForEach(Array(visible.enumerated()), id: \.offset) { rowIndex, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                Text(verbatim: cell).font(OMFonts.small).textSelection(.enabled)
                                    .padding(.horizontal, 12).padding(.vertical, 6)
                                    .frame(minWidth: 80, alignment: .leading)
                            }
                        }
                        .background(rowIndex.isMultiple(of: 2) ? Color.clear : OMColors.subtleFill)
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.automatic)
            .omSolidCard()
            if !showAll, sorted.count > Self.previewRows {
                Button("显示全部 \(sorted.count) 行") { showAll = true }.buttonStyle(.omPlain)
            }
        }
    }

    private func header(_ name: String, _ index: Int) -> some View {
        Button { sort.toggle(index) } label: {
            HStack(spacing: 4) {
                Text(verbatim: name).font(OMFonts.small.weight(.medium)).foregroundStyle(OMColors.secondaryText)
                if sort.column == index {
                    Image.om(sort.ascending ? "arrow-up" : "arrow-down", size: 10).foregroundStyle(OMColors.accent)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .frame(minWidth: 80, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "按 \(name) 排序"))
    }
}

// MARK: - 图表

/// 图表视图(画布块与会话 ```chart 围栏共用)。
struct CanvasChartView: View {
    let chart: CanvasChart

    private struct Point: Identifiable {
        let id: Int
        let label: String
        let series: String
        let value: Double
    }

    private var points: [Point] {
        var result: [Point] = []
        for series in chart.series {
            for (index, value) in series.values.enumerated() where chart.labels.indices.contains(index) {
                result.append(Point(id: result.count, label: chart.labels[index], series: series.name, value: value))
            }
        }
        return result
    }

    private var seriesNames: [String] { chart.series.map(\.name) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title = chart.title, !title.isEmpty { Text(verbatim: title).font(OMFonts.body.weight(.medium)) }
            Group {
                if chart.kind == .pie { pie } else { cartesian }
            }
            .frame(height: chart.kind == .pie ? 240 : 220)
            .accessibilityLabel(chart.title ?? String(localized: "图表"))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .omSolidCard()
    }

    private var cartesian: some View {
        Chart(points) { point in
            switch chart.kind {
            case .line:
                LineMark(x: .value("x", point.label), y: .value("y", point.value), series: .value("series", point.series))
                    .foregroundStyle(by: .value("series", point.series))
                PointMark(x: .value("x", point.label), y: .value("y", point.value))
                    .foregroundStyle(by: .value("series", point.series))
            case .area:
                AreaMark(x: .value("x", point.label), y: .value("y", point.value), series: .value("series", point.series))
                    .foregroundStyle(by: .value("series", point.series))
                    .opacity(0.45)
            default:
                BarMark(x: .value("x", point.label), y: .value("y", point.value))
                    .foregroundStyle(by: .value("series", point.series))
                    .position(by: .value("series", point.series))
                    .cornerRadius(3)
            }
        }
        .chartForegroundStyleScale(domain: seriesNames, range: seriesNames.indices.map { OMColors.chart($0) })
        .chartLegend(seriesNames.count > 1 ? .visible : .hidden)
        .chartLegend(position: .bottom, alignment: .leading)
    }

    private var pie: some View {
        Chart(points) { point in
            SectorMark(angle: .value("value", max(point.value, 0)), innerRadius: .ratio(0.55), angularInset: 1.5)
                .cornerRadius(3)
                .foregroundStyle(by: .value("label", point.label))
        }
        .chartForegroundStyleScale(domain: chart.labels, range: chart.labels.indices.map { OMColors.chart($0) })
        .chartLegend(position: .trailing, alignment: .center)
    }
}

// MARK: - 提示框

private struct CanvasCalloutView: View {
    let tone: CanvasTone
    let title: String?
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image.om(tone.icon, size: 14).foregroundStyle(tone.color).padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                if let title, !title.isEmpty { Text(verbatim: title).font(OMFonts.body.weight(.medium)) }
                MarkdownView(text: text)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(tone.color.opacity(0.1), in: RoundedRectangle(cornerRadius: OMMetrics.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: OMMetrics.cardRadius, style: .continuous).strokeBorder(tone.color.opacity(0.3), lineWidth: 0.5))
    }
}

// MARK: - 图片

private struct CanvasImageView: View {
    let source: String
    let caption: String?
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if let image {
                    Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, alignment: .leading)
                } else if failed {
                    Label(String(localized: "图片无法加载:\(source)"), om: "image").font(OMFonts.small).foregroundStyle(OMColors.tertiaryText)
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading).omSolidCard()
                } else {
                    OMSpinner(.small).frame(maxWidth: .infinity, minHeight: 80)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: OMMetrics.cardRadius, style: .continuous))
            if let caption, !caption.isEmpty { Text(verbatim: caption).font(OMFonts.caption).foregroundStyle(OMColors.secondaryText) }
        }
        .task(id: source) { await load() }
    }

    private func load() async {
        let value = source
        let loaded: NSImage? = await Task.detached(priority: .userInitiated) {
            let lower = value.lowercased()
            if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
                guard let url = URL(string: value), let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
                return NSImage(data: data)
            }
            return NSImage(contentsOfFile: (value as NSString).expandingTildeInPath)
        }.value
        image = loaded
        failed = loaded == nil
    }
}

// MARK: - 分区

private struct CanvasSectionView: View {
    let title: String
    let initiallyCollapsed: Bool
    let blocks: [CanvasBlock]
    @State private var collapsed: Bool?

    private var isCollapsed: Bool { collapsed ?? initiallyCollapsed }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { omWithAnimation(OMMotion.standard) { collapsed = !isCollapsed } } label: {
                HStack(spacing: 6) {
                    Image.om(isCollapsed ? "chevron-right" : "chevron-down", size: 12).foregroundStyle(OMColors.tertiaryText)
                    Text(verbatim: title).font(OMFonts.body.weight(.medium))
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue(isCollapsed ? String(localized: "已折叠") : String(localized: "已展开"))
            if !isCollapsed {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in CanvasBlockView(block: block) }
                }
                .padding(.leading, 18)
            }
        }
    }
}
