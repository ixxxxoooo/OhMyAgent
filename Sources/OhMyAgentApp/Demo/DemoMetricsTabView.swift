// @author ixxxxoooo
// 演示指标标签页:展示性能实验室基准的结果(按分类的度量表 + 真实内存曲线),并提供「运行」入口。
// 数据来自 `DemoBenchmarkRunner`;颜色/字号/按钮全部走设计令牌。

import DemoKit
import DesignSystem
import IconKit
import SwiftUI

/// 演示指标面板(标签页内容)。
struct DemoMetricsTabView: View {
    private let runner = DemoBenchmarkRunner.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                summary
                if !runner.report.memory.isEmpty { MemoryCurveView(points: runner.report.memory) }
                ForEach(DemoMetricCategory.allCases, id: \.self) { category in
                    categorySection(category)
                }
            }
            .padding(20)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    // MARK: 头部

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("演示指标").font(OMFonts.title).foregroundStyle(OMColors.primaryText)
                Text("在性能实验室里实测:项目打开、会话加载、复制、渲染、模型/引擎切换与真实内存。")
                    .font(OMFonts.small).foregroundStyle(OMColors.secondaryText)
            }
            Spacer(minLength: 12)
            if runner.isRunning {
                OMSpinner(.small)
                Text(verbatim: runner.currentStep).font(OMFonts.small).foregroundStyle(OMColors.secondaryText).lineLimit(1)
                Button("停止") { runner.cancel() }.buttonStyle(OMButtonStyle(.secondary))
            } else {
                Button("运行全部") { Task { await runner.run() } }.buttonStyle(OMButtonStyle(.primary))
            }
        }
    }

    private var summary: some View {
        let counts = runner.report.counts
        return HStack(spacing: 16) {
            statChip("通过", counts.pass, OMColors.success)
            statChip("偏慢", counts.slow, OMColors.warning)
            statChip("失败", counts.fail, OMColors.danger)
            if let memory = runner.report.memorySummary {
                Text(verbatim: "内存 \(Int(memory.startMB)) → 峰值 \(Int(memory.peakMB)) → \(Int(memory.endMB)) MB")
                    .font(OMFonts.small).foregroundStyle(OMColors.secondaryText)
            }
            Spacer()
        }
    }

    private func statChip(_ title: LocalizedStringKey, _ count: Int, _ color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(title).font(OMFonts.small).foregroundStyle(OMColors.secondaryText)
            Text(verbatim: "\(count)").font(OMFonts.body).foregroundStyle(OMColors.primaryText)
        }
    }

    // MARK: 分类表

    @ViewBuilder
    private func categorySection(_ category: DemoMetricCategory) -> some View {
        let list = runner.report.metrics(in: category)
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(verbatim: category.title).font(OMFonts.sectionTitle).foregroundStyle(OMColors.primaryText)
                    Spacer()
                    if !runner.isRunning {
                        Button("只运行此项") { Task { await runner.run(categories: [category]) } }.buttonStyle(OMButtonStyle(.plain))
                    }
                }
                .padding(.bottom, 8)
                ForEach(list) { metric in
                    MetricRow(metric: metric)
                    if metric.id != list.last?.id { Divider().overlay(OMColors.hairline) }
                }
            }
            .padding(12)
            .background(OMColors.card, in: RoundedRectangle(cornerRadius: OMRadius.card))
        }
    }
}

/// 一行度量。
private struct MetricRow: View {
    let metric: DemoMetric

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Circle().fill(color).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: metric.title).font(OMFonts.body).foregroundStyle(OMColors.primaryText)
                Text(verbatim: metric.purpose + (metric.detail.isEmpty ? "" : "(\(metric.detail))"))
                    .font(OMFonts.caption).foregroundStyle(OMColors.secondaryText)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 2) {
                Text(verbatim: metric.valueText).font(OMFonts.mono).foregroundStyle(OMColors.primaryText)
                if let budget = metric.budget {
                    Text(verbatim: "预算 \(Int(budget)) \(metric.unit.suffix)").font(OMFonts.caption).foregroundStyle(OMColors.tertiaryText)
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var color: Color {
        switch metric.status {
        case .pass: OMColors.success
        case .slow: OMColors.warning
        case .fail: OMColors.danger
        case .info: OMColors.tertiaryText
        }
    }
}

/// 真实内存曲线:应用本体(实线)与子进程(虚线),阶段切换处画竖线并标注阶段名。
private struct MemoryCurveView: View {
    let points: [DemoMemoryPoint]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("真实内存曲线").font(OMFonts.sectionTitle).foregroundStyle(OMColors.primaryText)
            Canvas { context, size in draw(&context, size: size) }
                .frame(height: 160)
            HStack(spacing: 12) {
                legend("应用本体", OMColors.accent)
                legend("子进程", OMColors.tertiaryText)
                Spacer()
                if let last = points.last {
                    Text(verbatim: "当前 \(Int(last.appMB)) MB · 阶段 \(last.phase)").font(OMFonts.caption).foregroundStyle(OMColors.secondaryText)
                }
            }
        }
        .padding(12)
        .background(OMColors.card, in: RoundedRectangle(cornerRadius: OMRadius.card))
    }

    private func legend(_ title: LocalizedStringKey, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Rectangle().fill(color).frame(width: 12, height: 2)
            Text(title).font(OMFonts.caption).foregroundStyle(OMColors.secondaryText)
        }
    }

    private func draw(_ context: inout GraphicsContext, size: CGSize) {
        guard points.count > 1, let maxTime = points.last?.seconds, maxTime > 0 else { return }
        let maxMB = max(points.map { max($0.appMB, $0.childrenMB) }.max() ?? 1, 1) * 1.1
        func point(_ p: DemoMemoryPoint, _ value: Double) -> CGPoint {
            CGPoint(x: size.width * p.seconds / maxTime, y: size.height * (1 - value / maxMB))
        }
        // 阶段分隔线
        var previous = points[0].phase
        for p in points where p.phase != previous {
            let x = size.width * p.seconds / maxTime
            var line = Path()
            line.move(to: CGPoint(x: x, y: 0)); line.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(line, with: .color(OMColors.hairline), lineWidth: 1)
            context.draw(Text(verbatim: p.phase).font(OMFonts.caption).foregroundStyle(OMColors.tertiaryText), at: CGPoint(x: x + 3, y: 8), anchor: .leading)
            previous = p.phase
        }
        var app = Path(), children = Path()
        for (index, p) in points.enumerated() {
            let a = point(p, p.appMB), c = point(p, p.childrenMB)
            if index == 0 { app.move(to: a); children.move(to: c) } else { app.addLine(to: a); children.addLine(to: c) }
        }
        context.stroke(children, with: .color(OMColors.tertiaryText), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        context.stroke(app, with: .color(OMColors.accent), lineWidth: 1.5)
        context.draw(Text(verbatim: "\(Int(maxMB)) MB").font(OMFonts.caption).foregroundStyle(OMColors.tertiaryText), at: CGPoint(x: size.width - 2, y: 8), anchor: .trailing)
    }
}
