// @author ixxxxoooo
// 演示用画布:覆盖全部块类型(标题、统计、图表、表格、提示框、分区、代码、Mermaid、图片),
// 与演示场景 `canvas` 里的 `canvas_create` 工具调用对应,写入沙盒的 canvases 目录。

import CanvasKit
import Foundation

/// 演示画布数据。
public enum DemoCanvas {
    /// 演示画布的固定标识(场景里的工具结果引用它)。
    public static let id = "demo-quarterly-report"

    /// 构造演示画布文档。
    /// - Parameters:
    ///   - projectPath: 所属项目路径
    ///   - now: 基准时间
    public static func document(projectPath: String, now: Date = Date()) -> CanvasDocument {
        let blocks: [CanvasBlock] = [
            .heading(text: "Atlas 第三季度质量周报", level: 1),
            .markdown("本季度重点是**路由性能**与**指标覆盖**。下方数据由 Agent 汇总,可在源码视图查看 JSON。"),
            .stats([
                CanvasStat(label: "合并 PR", value: "42", delta: "+8 较上季", tone: .success),
                CanvasStat(label: "平均响应", value: "118 ms", delta: "-23 ms", tone: .success),
                CanvasStat(label: "未关闭缺陷", value: "7", delta: "+2", tone: .warning),
                CanvasStat(label: "测试覆盖率", value: "86%", tone: .info),
            ]),
            .chart(CanvasChart(kind: .bar, title: "每月合并 PR", labels: ["7 月", "8 月", "9 月"],
                               series: [CanvasSeries(name: "功能", values: [9, 14, 11]), CanvasSeries(name: "修复", values: [6, 5, 9])])),
            .chart(CanvasChart(kind: .line, title: "响应时间(ms)", labels: ["第 1 周", "第 2 周", "第 3 周", "第 4 周"],
                               series: [CanvasSeries(name: "P50", values: [141, 130, 124, 118]), CanvasSeries(name: "P95", values: [320, 290, 260, 244])])),
            .chart(CanvasChart(kind: .pie, title: "缺陷来源", labels: ["路由", "缓存", "解析", "其他"], series: [CanvasSeries(name: "数量", values: [9, 5, 3, 2])])),
            .table(CanvasTable(columns: ["模块", "负责人", "覆盖率", "状态"], rows: [
                ["AtlasCore", "ixxxxoooo", "92", "稳定"], ["Router", "mei", "88", "稳定"], ["Metrics", "ixxxxoooo", "74", "进行中"],
                ["Cache", "lin", "81", "评审中"], ["CLI", "mei", "69", "进行中"],
            ], title: "模块健康度")),
            .callout(tone: .warning, title: "风险", text: "`Metrics` 的覆盖率低于 80% 的目标,发布前需要补齐。"),
            .section(title: "附录:实现细节", collapsed: true, blocks: [
                .code(language: "swift", text: "router.register(\"/metrics\") { request in\n    Metrics.shared.count(request.path)\n}"),
                .mermaid("graph TD\n  A[请求] --> B{路由匹配}\n  B -->|命中| C[处理器]\n  B -->|未命中| D[404]"),
            ]),
            .divider,
            .image(source: (projectPath as NSString).appendingPathComponent("assets/logo.png"), caption: "Atlas 标志"),
        ]
        return CanvasDocument(id: id, title: "Atlas 第三季度质量周报", blocks: blocks, projectPath: projectPath,
                              createdAt: now.addingTimeInterval(-3_600), updatedAt: now, revision: 2)
    }

    /// 写入演示画布(每次刷新)。
    /// - Parameters:
    ///   - home: 沙盒主目录
    ///   - projectPath: 所属项目路径
    ///   - now: 基准时间
    public static func write(home: URL, projectPath: String, now: Date = Date()) throws {
        let store = CanvasStore(directory: CanvasStore.defaultDirectory(home: home))
        try store.save(document(projectPath: projectPath, now: now))
    }
}
