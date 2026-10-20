// @author ixxxxoooo
// 演示指标:性能实验室的度量数据模型(无视图)。
// 一次基准运行产出一份 `DemoMetricsReport`:每个度量点带「测什么」「预算」「结果状态」,
// 另含运行期的内存曲线(应用 + 子进程)。可序列化为 JSON(`demo-metrics.json`)与 Markdown 汇总。

import Foundation

/// 度量分类(对应演示空间要覆盖的四类需求 + 打开速度)。
public enum DemoMetricCategory: String, Codable, CaseIterable, Sendable {
    /// 项目打开与文件索引
    case open
    /// 会话加载(历史回放)
    case load
    /// 复制(跨叶子选择)
    case copy
    /// 渲染(Markdown / 表格 / 图表 / Mermaid / 代码)
    case render
    /// 模型与引擎切换、会话恢复
    case switching
    /// 运行时内存
    case memory

    /// 中文标题。
    public var title: String {
        switch self {
        case .open: "项目打开与索引"
        case .load: "会话加载"
        case .copy: "复制"
        case .render: "渲染"
        case .switching: "模型/引擎切换与恢复"
        case .memory: "运行时内存"
        }
    }
}

/// 度量单位。
public enum DemoMetricUnit: String, Codable, Sendable {
    case milliseconds
    case megabytes

    /// 展示用后缀。
    public var suffix: String { self == .milliseconds ? "ms" : "MB" }
}

/// 度量结果状态。
public enum DemoMetricStatus: String, Codable, Sendable {
    /// 在预算内
    case pass
    /// 超预算但不足两倍
    case slow
    /// 超过两倍预算(或运行失败)
    case fail
    /// 未运行或无预算(仅展示)
    case info
}

/// 一个度量点。
public struct DemoMetric: Codable, Identifiable, Equatable, Sendable {
    /// 稳定标识(同 `DemoBenchmarkCatalog` 中的条目一致)
    public let id: String
    public let category: DemoMetricCategory
    /// 名称
    public let title: String
    /// 这个度量在测什么
    public let purpose: String
    public let unit: DemoMetricUnit
    /// 测得的值;未运行或失败为 nil
    public var value: Double?
    /// 预算(与 `unit` 同单位);nil 表示仅展示
    public let budget: Double?
    /// 补充说明(规模、失败原因等)
    public var detail: String

    public init(id: String, category: DemoMetricCategory, title: String, purpose: String, unit: DemoMetricUnit = .milliseconds,
                value: Double? = nil, budget: Double? = nil, detail: String = "") {
        self.id = id
        self.category = category
        self.title = title
        self.purpose = purpose
        self.unit = unit
        self.value = value
        self.budget = budget
        self.detail = detail
    }

    /// 结果状态:无值(失败)且有预算记为失败,没有预算为仅展示。
    public var status: DemoMetricStatus {
        guard let budget else { return .info }
        guard let value else { return detail.isEmpty ? .info : .fail }
        if value <= budget { return .pass }
        return value <= budget * 2 ? .slow : .fail
    }

    /// 展示文本,如 `123 ms`。
    public var valueText: String {
        guard let value else { return "—" }
        return value >= 100 ? "\(Int(value.rounded())) \(unit.suffix)" : String(format: "%.1f %@", value, unit.suffix)
    }
}

/// 内存曲线上的一个点。
public struct DemoMemoryPoint: Codable, Equatable, Sendable {
    /// 自运行开始的秒数
    public let seconds: Double
    /// 应用本体占用(MB,phys_footprint)
    public let appMB: Double
    /// 子进程占用合计(MB)
    public let childrenMB: Double
    /// 当时所处的阶段名
    public let phase: String

    public init(seconds: Double, appMB: Double, childrenMB: Double, phase: String) {
        self.seconds = seconds
        self.appMB = appMB
        self.childrenMB = childrenMB
        self.phase = phase
    }
}

/// 内存曲线的汇总。
public struct DemoMemorySummary: Equatable, Sendable {
    /// 起点占用
    public let startMB: Double
    /// 峰值占用
    public let peakMB: Double
    /// 终点占用
    public let endMB: Double
}

/// 一次基准运行的完整报告。
public struct DemoMetricsReport: Codable, Equatable, Sendable {
    public var startedAt: Date
    public var finishedAt: Date?
    public var metrics: [DemoMetric]
    public var memory: [DemoMemoryPoint]

    public init(startedAt: Date = Date(), finishedAt: Date? = nil, metrics: [DemoMetric] = [], memory: [DemoMemoryPoint] = []) {
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.metrics = metrics
        self.memory = memory
    }

    /// 写入(或按 `id` 替换)一个度量。
    /// - Parameter metric: 度量
    public mutating func record(_ metric: DemoMetric) {
        if let index = metrics.firstIndex(where: { $0.id == metric.id }) { metrics[index] = metric } else { metrics.append(metric) }
    }

    /// 某分类下的度量。
    /// - Parameter category: 分类
    public func metrics(in category: DemoMetricCategory) -> [DemoMetric] { metrics.filter { $0.category == category } }

    /// 各状态计数。
    public var counts: (pass: Int, slow: Int, fail: Int) {
        (metrics.filter { $0.status == .pass }.count, metrics.filter { $0.status == .slow }.count, metrics.filter { $0.status == .fail }.count)
    }

    /// 内存曲线汇总;没有采样时为 nil。
    public var memorySummary: DemoMemorySummary? {
        guard let first = memory.first, let last = memory.last else { return nil }
        return DemoMemorySummary(startMB: first.appMB, peakMB: memory.map(\.appMB).max() ?? first.appMB, endMB: last.appMB)
    }

    /// 编码为 JSON(日期用 ISO8601,键排序便于对比)。
    /// - Returns: JSON 数据
    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    /// 从 JSON 解码。
    /// - Parameter data: JSON 数据
    public static func decode(_ data: Data) throws -> DemoMetricsReport {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(DemoMetricsReport.self, from: data)
    }

    /// Markdown 汇总(按分类分节,含状态图标与内存概览),供脚本打印与存档。
    public func markdown() -> String {
        var lines = ["# 演示空间性能报告", ""]
        let counts = counts
        lines.append("通过 \(counts.pass) · 偏慢 \(counts.slow) · 失败 \(counts.fail) · 共 \(metrics.count) 项")
        if let memory = memorySummary {
            lines.append("内存(应用):起点 \(Int(memory.startMB)) MB → 峰值 \(Int(memory.peakMB)) MB → 终点 \(Int(memory.endMB)) MB")
        }
        for category in DemoMetricCategory.allCases {
            let list = metrics(in: category)
            guard !list.isEmpty else { continue }
            lines += ["", "## \(category.title)", "", "| 状态 | 项目 | 结果 | 预算 | 说明 |", "| --- | --- | ---: | ---: | --- |"]
            for metric in list {
                let icon = switch metric.status { case .pass: "✅"; case .slow: "⚠️"; case .fail: "❌"; case .info: "ℹ️" }
                let budget = metric.budget.map { "\(Int($0)) \(metric.unit.suffix)" } ?? "—"
                lines.append("| \(icon) | \(metric.title) | \(metric.valueText) | \(budget) | \(metric.purpose)\(metric.detail.isEmpty ? "" : "(\(metric.detail))") |")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

/// 一个待运行的基准条目(目录项:描述「测什么」与预算)。
public struct DemoBenchmarkItem: Equatable, Sendable {
    public let id: String
    public let category: DemoMetricCategory
    public let title: String
    public let purpose: String
    public let unit: DemoMetricUnit
    public let budget: Double?

    /// 生成尚未有结果的度量点。
    public var placeholder: DemoMetric {
        DemoMetric(id: id, category: category, title: title, purpose: purpose, unit: unit, budget: budget)
    }
}

/// 基准目录:全部要在演示空间里测的项目,预算是「体验可接受」的参考线(可随基线调整)。
public enum DemoBenchmarkCatalog {
    private static func ms(_ id: String, _ category: DemoMetricCategory, _ title: String, _ purpose: String, budget: Double?) -> DemoBenchmarkItem {
        DemoBenchmarkItem(id: id, category: category, title: title, purpose: purpose, unit: .milliseconds, budget: budget)
    }

    private static func mb(_ id: String, _ title: String, _ purpose: String, budget: Double?) -> DemoBenchmarkItem {
        DemoBenchmarkItem(id: id, category: .memory, title: title, purpose: purpose, unit: .megabytes, budget: budget)
    }

    /// 全部条目(顺序即运行与展示顺序)。
    public static let items: [DemoBenchmarkItem] = [
        ms("open.perf-longchat", .open, "打开 perf-longchat", "切换到项目并让会话就绪(含首次创建)", budget: 800),
        ms("open.perf-render", .open, "打开 perf-render", "切换到项目并让会话就绪", budget: 800),
        ms("open.perf-multitab", .open, "打开 perf-multitab", "切换到含 1 万文件目录的项目并让会话就绪", budget: 800),
        ms("open.index-10k", .open, "文件索引:1 万文件深层目录", "后台扫描 perf-multitab(含 perf-fs 的 10000 个文件)建立快速打开索引", budget: 3_000),
        ms("load.long2000", .load, "加载 2000 轮长会话", "session/load 回放全部轮次并构建时间线", budget: 6_000),
        ms("load.mixed800", .load, "加载 800 轮混合内容", "回放含表格/图表/Mermaid/Diff/终端输出的混合会话", budget: 4_000),
        ms("load.heavy", .load, "加载单轮超长输出", "回放 2000 行终端 + 大 Diff + 超长代码块", budget: 3_000),
        ms("load.gallery", .load, "加载渲染画廊", "回放 60×7 宽表格、K 线、全部 Mermaid、12 种语言代码", budget: 3_000),
        ms("copy.select-all", .copy, "跨叶子全选并复制", "对已挂载的最近 40 轮执行全选 + 拼接文本", budget: 400),
        ms("render.markdown-parse", .render, "Markdown 解析", "解析 render-lab.md(12 节 + 60 行宽表 + 代码 + Mermaid)", budget: 80),
        ms("render.markdown-runs", .render, "Markdown 文字段富文本", "把解析出的块构建为富文本(文字叶子)", budget: 120),
        ms("render.table", .render, "宽表格解析", "60 行 × 7 列的表格块", budget: 40),
        ms("render.chart", .render, "图表解析", "折线图(三序列)+ 60 根 K 线(MA5/10/20)", budget: 60),
        ms("render.mermaid", .render, "Mermaid 全图种", "流程/时序/状态/类/饼图/甘特共 6 张图的解析 + 布局", budget: 300),
        ms("render.code", .render, "代码高亮 600 个函数", "对 3000+ 行 Swift 做完整语法高亮", budget: 500),
        ms("render.markdown-live", .render, "所见即所得布局", "对 render-lab.md 做 MarkdownLive 块与样式布局", budget: 150),
        ms("switch.model", .switching, "切换模型", "在会话里切换模型选项并确认生效", budget: 600),
        ms("switch.engine-restore", .switching, "切换引擎并恢复会话", "新建引擎会话替换当前标签,再恢复同一个 800 轮会话", budget: 5_000),
        mb("memory.baseline", "内存基线", "运行开始时应用本体占用(仅展示)", budget: nil),
        mb("memory.after-load", "加载后增量", "加载 2000 + 800 轮会话后相对基线增加的占用", budget: 600),
        mb("memory.per-1k-turns", "每千轮占用", "2000 轮长会话相对基线的增量 ÷ 2", budget: 250),
        mb("memory.peak", "运行峰值", "整个基准期间应用本体的最高占用", budget: 1_500),
        mb("memory.after-release", "释放后残留", "关闭加载的标签并稍候后,相对基线仍保留的占用", budget: 300),
        mb("memory.children", "子进程合计", "运行结束时 Agent 子进程占用合计(演示用脚本化 Agent 在进程内,通常为 0)", budget: nil),
    ]

    /// 某分类下的条目。
    /// - Parameter category: 分类
    public static func items(in category: DemoMetricCategory) -> [DemoBenchmarkItem] { items.filter { $0.category == category } }

    /// 按 id 查找。
    /// - Parameter id: 条目 id
    public static func item(id: String) -> DemoBenchmarkItem? { items.first { $0.id == id } }

    /// 解析 `OMA_DEMO_BENCH` 的取值(`all` 或逗号分隔的分类名)。
    /// - Parameter raw: 环境变量原文
    /// - Returns: 要运行的分类;空串/非法返回 nil
    public static func categories(from raw: String?) -> Set<DemoMetricCategory>? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces).lowercased(), !raw.isEmpty else { return nil }
        if raw == "all" || raw == "1" { return Set(DemoMetricCategory.allCases) }
        let picked = raw.split(separator: ",").compactMap { DemoMetricCategory(rawValue: String($0).trimmingCharacters(in: .whitespaces)) }
        return picked.isEmpty ? nil : Set(picked)
    }
}
