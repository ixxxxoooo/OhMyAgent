// @author ixxxxoooo
// Canvas 文档模型:标题 + 块列表的声明式画布(对照 Cursor Canvases,但不用 React,而是原生块渲染)。
// 块以 `type` 字段区分,JSON 形态稳定,既是 Agent 工具的入参,也是落盘格式。

import Foundation

/// 文档规模上限(防止模型一次生成过大的画布拖垮界面)。
public enum CanvasLimits {
    /// 块总数上限(含分区内嵌套)
    public static let maxBlocks = 200
    /// 表格行数上限
    public static let maxTableRows = 2000
    /// 表格列数上限
    public static let maxTableColumns = 50
    /// 图表数据点上限(所有系列合计)
    public static let maxChartPoints = 1000
    /// 单段文本(Markdown、代码、Mermaid)字符数上限
    public static let maxTextLength = 100_000
    /// 分区嵌套深度上限
    public static let maxDepth = 3
}

/// 统计卡的色调。
public enum CanvasTone: String, Codable, Sendable, Equatable, CaseIterable {
    case neutral, info, success, warning, danger
}

/// 统计卡里的一项。
public struct CanvasStat: Codable, Sendable, Equatable {
    public var label: String
    public var value: String
    /// 变化说明(如「+12%」),可空
    public var delta: String?
    public var tone: CanvasTone

    public init(label: String, value: String, delta: String? = nil, tone: CanvasTone = .neutral) {
        self.label = label
        self.value = value
        self.delta = delta
        self.tone = tone
    }
}

/// 表格。
public struct CanvasTable: Codable, Sendable, Equatable {
    public var columns: [String]
    public var rows: [[String]]
    /// 表格标题,可空
    public var title: String?

    public init(columns: [String], rows: [[String]], title: String? = nil) {
        self.columns = columns
        self.rows = rows
        self.title = title
    }
}

/// 图表种类。
public enum CanvasChartKind: String, Codable, Sendable, Equatable, CaseIterable {
    case bar, line, area, pie
}

/// 图表中的一个系列。
public struct CanvasSeries: Codable, Sendable, Equatable {
    public var name: String
    public var values: [Double]

    public init(name: String, values: [Double]) {
        self.name = name
        self.values = values
    }
}

/// 图表:`labels` 为横轴(饼图为扇区名),每个系列的 `values` 与之等长。
public struct CanvasChart: Codable, Sendable, Equatable {
    public var kind: CanvasChartKind
    public var title: String?
    public var labels: [String]
    public var series: [CanvasSeries]

    public init(kind: CanvasChartKind, title: String? = nil, labels: [String], series: [CanvasSeries]) {
        self.kind = kind
        self.title = title
        self.labels = labels
        self.series = series
    }

    /// 数据点总数。
    public var pointCount: Int { series.reduce(0) { $0 + $1.values.count } }
}

/// 画布块。
public indirect enum CanvasBlock: Sendable, Equatable {
    case heading(text: String, level: Int)
    case markdown(String)
    case stats([CanvasStat])
    case table(CanvasTable)
    case chart(CanvasChart)
    case callout(tone: CanvasTone, title: String?, text: String)
    case code(language: String?, text: String)
    /// 图片(本机路径或 http(s) 地址)
    case image(source: String, caption: String?)
    case mermaid(String)
    case section(title: String, collapsed: Bool, blocks: [CanvasBlock])
    case divider

    /// 块类型名(JSON 的 `type`)。
    public var typeName: String {
        switch self {
        case .heading: return "heading"
        case .markdown: return "markdown"
        case .stats: return "stats"
        case .table: return "table"
        case .chart: return "chart"
        case .callout: return "callout"
        case .code: return "code"
        case .image: return "image"
        case .mermaid: return "mermaid"
        case .section: return "section"
        case .divider: return "divider"
        }
    }

    /// 含自身与全部嵌套块的数量。
    public var totalCount: Int {
        if case .section(_, _, let children) = self { return 1 + children.reduce(0) { $0 + $1.totalCount } }
        return 1
    }
}

/// 画布文档。
public struct CanvasDocument: Codable, Sendable, Equatable, Identifiable {
    /// 文档标识(小写字母、数字、连字符)
    public var id: String
    public var title: String
    public var blocks: [CanvasBlock]
    /// 所属项目路径(用于按项目筛选,可空)
    public var projectPath: String?
    public var createdAt: Date
    public var updatedAt: Date
    /// 修订号(每次更新 +1)
    public var revision: Int

    public init(id: String, title: String, blocks: [CanvasBlock], projectPath: String? = nil,
                createdAt: Date = Date(), updatedAt: Date = Date(), revision: Int = 1) {
        self.id = id
        self.title = title
        self.blocks = blocks
        self.projectPath = projectPath
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.revision = revision
    }

    /// 块总数(含嵌套)。
    public var blockCount: Int { blocks.reduce(0) { $0 + $1.totalCount } }
}

/// 文档摘要(列表用)。
public struct CanvasSummary: Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var projectPath: String?
    public var updatedAt: Date
    public var blockCount: Int
}
