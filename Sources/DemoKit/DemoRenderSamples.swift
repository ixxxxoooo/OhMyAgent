// @author ixxxxoooo
// 渲染基准的确定性素材:大 Markdown、宽表格、图表 JSON、Mermaid 源码与长代码。
// 与「渲染画廊」会话、`perf-render` 项目里的文件是同一批内容,基准与肉眼看到的一致。

import Foundation

/// 渲染基准素材(全部确定性生成)。
public enum DemoRenderSamples {
    /// 大 Markdown 文档(与 `perf-render/docs/render-lab.md` 相同)。
    public static var markdownDocument: String { DemoPerfProjects.renderLabMarkdown }

    /// 60 行 × 7 列的宽表格(Markdown 表格语法)。
    public static var tableMarkdown: String {
        let rows = (1...60).map { "| 模块 \($0) | \($0 * 13 % 97) | \(Double($0 * 37 % 1000) / 10)% | 第 \($0) 行说明文字,用来撑出较长的单元格 | 状态\($0 % 4) | 负责人\($0 % 7) | 备注\($0 % 9) |" }
        return (["| 模块 | 数量 | 占比 | 说明 | 状态 | 负责人 | 备注 |", "| --- | ---: | ---: | --- | --- | --- | --- |"] + rows).joined(separator: "\n")
    }

    /// 折线图 JSON(三序列)。
    public static let lineChartJSON = "{\"kind\":\"line\",\"title\":\"多序列折线\",\"labels\":[\"1月\",\"2月\",\"3月\",\"4月\",\"5月\",\"6月\"],\"series\":[{\"name\":\"A\",\"values\":[10,20,15,30,25,40]},{\"name\":\"B\",\"values\":[12,18,25,28,31,35]},{\"name\":\"C\",\"values\":[5,9,14,12,20,26]}]}"

    /// 60 根 K 线 JSON(MA5/10/20 + 成交量)。
    public static var candleChartJSON: String {
        let candles = (0..<60).map { i -> String in
            let base = 1500.0 + Double(i) * 2 + (i % 5 == 0 ? -25 : Double(i % 3) * 8)
            let close = base + (i % 2 == 0 ? 14 : -9)
            return "[\(Int(base)),\(Int(max(base, close)) + 12),\(Int(min(base, close)) - 10),\(Int(close)),\(20_000 + i * 900)]"
        }.joined(separator: ",")
        let labels = (0..<60).map { "\"D\($0 + 1)\"" }.joined(separator: ",")
        return "{\"kind\":\"candle\",\"title\":\"60 根 K 线\",\"labels\":[\(labels)],\"candles\":[\(candles)],\"ma\":[5,10,20],\"up\":\"red\"}"
    }

    /// 6 种受支持的 Mermaid 图(流程/时序/状态/类/饼图/甘特)。
    public static let mermaidSources: [String] = [
        "flowchart TD\n  A[用户请求] --> B{已登录?}\n  B -->|是| C[读取数据]\n  B -->|否| D[跳转登录]\n  D --> A\n  C --> E([完成])\n  subgraph 后端\n    C --> F[(数据库)]\n  end",
        "sequenceDiagram\n  autonumber\n  participant U as 用户\n  participant S as 服务\n  U->>+S: 发起请求\n  S-->>-U: 返回结果\n  Note over U,S: 完成\n  loop 每分钟\n    U->>U: 自检\n  end",
        "stateDiagram-v2\n  [*] --> Idle\n  Idle --> Running : start\n  Running --> Idle : stop\n  Running --> [*]",
        "classDiagram\n  class Animal {\n    +String name\n    +eat() void\n  }\n  Animal <|-- Dog\n  Animal <|-- Cat",
        "pie showData title 占比\n  \"甲\" : 30\n  \"乙\" : 50\n  \"丙\" : 20",
        "gantt\n  title 计划\n  dateFormat YYYY-MM-DD\n  section 设计\n  调研 :done, a1, 2026-01-01, 5d\n  方案 :a2, after a1, 3d\n  section 开发\n  实现 :crit, 2026-01-10, 2026-01-20",
    ]

    /// 长 Swift 代码(600 个函数,约 3600 行)。
    public static var largeSwift: String { DemoPerfProjects.swiftSource(module: "Large", functions: 600) }
}
