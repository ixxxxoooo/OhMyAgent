// @author ixxxxoooo
// 演示指标测试:状态判定、报告记录/序列化/Markdown、基准目录守卫、渲染素材规模。

import Foundation
import Testing
@testable import DemoKit

@Suite("演示指标")
struct DemoMetricsTests {
    private func metric(value: Double?, budget: Double?, detail: String = "") -> DemoMetric {
        DemoMetric(id: "x", category: .render, title: "x", purpose: "p", value: value, budget: budget, detail: detail)
    }

    @Test("状态:预算内通过,两倍内偏慢,更慢失败;无预算仅展示;有预算却失败为失败")
    func status() {
        #expect(metric(value: 100, budget: 100).status == .pass)
        #expect(metric(value: 150, budget: 100).status == .slow)
        #expect(metric(value: 200, budget: 100).status == .slow)
        #expect(metric(value: 201, budget: 100).status == .fail)
        #expect(metric(value: 5, budget: nil).status == .info)
        #expect(metric(value: nil, budget: 100).status == .info)               // 尚未运行
        #expect(metric(value: nil, budget: 100, detail: "超时").status == .fail) // 运行失败
    }

    @Test("取值展示:100 以上取整,以下保留一位小数,缺失为破折号")
    func valueText() {
        #expect(metric(value: 123.4, budget: nil).valueText == "123 ms")
        #expect(metric(value: 12.34, budget: nil).valueText == "12.3 ms")
        #expect(metric(value: nil, budget: nil).valueText == "—")
    }

    @Test("记录按 id 替换,分类与计数正确,内存汇总取起点/峰值/终点")
    func report() {
        var report = DemoMetricsReport()
        report.record(DemoMetric(id: "a", category: .load, title: "a", purpose: "", value: 10, budget: 100))
        report.record(DemoMetric(id: "b", category: .load, title: "b", purpose: "", value: 150, budget: 100))
        report.record(DemoMetric(id: "a", category: .load, title: "a", purpose: "", value: 500, budget: 100))
        #expect(report.metrics.count == 2)
        #expect(report.metrics(in: .load).count == 2 && report.metrics(in: .render).isEmpty)
        #expect(report.counts == (pass: 0, slow: 1, fail: 1))
        #expect(report.memorySummary == nil)
        report.memory = [DemoMemoryPoint(seconds: 0, appMB: 300, childrenMB: 0, phase: "基线"),
                         DemoMemoryPoint(seconds: 1, appMB: 900, childrenMB: 10, phase: "加载"),
                         DemoMemoryPoint(seconds: 2, appMB: 400, childrenMB: 0, phase: "释放")]
        #expect(report.memorySummary == DemoMemorySummary(startMB: 300, peakMB: 900, endMB: 400))
    }

    @Test("JSON 往返一致,Markdown 含分类标题与状态图标")
    func serialization() throws {
        var report = DemoMetricsReport(startedAt: Date(timeIntervalSince1970: 1_800_000_000))
        report.record(DemoMetric(id: "load.long2000", category: .load, title: "加载 2000 轮", purpose: "回放", value: 1234, budget: 6_000, detail: "4000 条"))
        report.memory = [DemoMemoryPoint(seconds: 0.5, appMB: 321, childrenMB: 0, phase: "基线")]
        let decoded = try DemoMetricsReport.decode(report.jsonData())
        #expect(decoded == report)
        let markdown = report.markdown()
        #expect(markdown.contains("## 会话加载") && markdown.contains("✅") && markdown.contains("1234 ms"))
        #expect(markdown.contains("内存(应用)"))
    }

    @Test("基准目录:id 唯一,每个分类都有条目,预算为正,占位符不带值")
    func catalogGuard() {
        let ids = DemoBenchmarkCatalog.items.map(\.id)
        #expect(Set(ids).count == ids.count)
        for category in DemoMetricCategory.allCases { #expect(!DemoBenchmarkCatalog.items(in: category).isEmpty, "\(category) 没有基准条目") }
        for item in DemoBenchmarkCatalog.items {
            #expect((item.budget ?? 1) > 0)
            #expect(item.placeholder.value == nil)
            #expect(item.id.hasPrefix(item.category == .switching ? "switch." : item.category.rawValue + "."))
        }
        // 用户要求覆盖的四类:复制/加载/打开、渲染、模型切换与恢复、真实内存
        #expect(DemoBenchmarkCatalog.item(id: "copy.select-all") != nil)
        #expect(DemoBenchmarkCatalog.item(id: "switch.engine-restore") != nil)
        #expect(DemoBenchmarkCatalog.item(id: "memory.after-release") != nil)
    }

    @Test("OMA_DEMO_BENCH 解析:all/1 全部,逗号分隔取分类,非法为 nil")
    func parseCategories() {
        #expect(DemoBenchmarkCatalog.categories(from: "all") == Set(DemoMetricCategory.allCases))
        #expect(DemoBenchmarkCatalog.categories(from: "1") == Set(DemoMetricCategory.allCases))
        #expect(DemoBenchmarkCatalog.categories(from: "load, render") == [.load, .render])
        #expect(DemoBenchmarkCatalog.categories(from: "bogus") == nil)
        #expect(DemoBenchmarkCatalog.categories(from: "") == nil)
        #expect(DemoBenchmarkCatalog.categories(from: nil) == nil)
    }

    @Test("渲染素材:大文档、60 行宽表、60 根 K 线、6 种 Mermaid、600 函数代码")
    func samples() {
        #expect(DemoRenderSamples.markdownDocument.contains("```mermaid") && DemoRenderSamples.markdownDocument.count > 5_000)
        #expect(DemoRenderSamples.tableMarkdown.split(separator: "\n").count == 62)
        #expect(DemoRenderSamples.candleChartJSON.contains("\"kind\":\"candle\""))
        #expect(DemoRenderSamples.mermaidSources.count == 6)
        #expect(DemoRenderSamples.largeSwift.split(separator: "\n").count > 3_000)
    }
}
