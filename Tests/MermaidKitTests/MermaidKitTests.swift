// @author ygw
// MermaidKit 测试:解析、布局无重叠、场景非空、错误处理。

import CoreGraphics
import Foundation
import Testing
@testable import MermaidKit

@Suite("Mermaid 流程图解析")
struct FlowchartParsingTests {
    private func model(_ s: String) throws -> FlowModel {
        try FlowchartParser.parse(Mermaid.cleanedLines(s))
    }

    @Test("基本节点形状与连线")
    func basic() throws {
        let m = try model("""
        flowchart LR
          A[开始] --> B{判断?}
          B -->|是| C([结束])
          B -- 否 --> D((圆))
          C -.-> E[(库)]
        """)
        #expect(m.direction == .leftRight)
        #expect(m.nodes["A"]?.shape == .rect)
        #expect(m.nodes["B"]?.shape == .diamond)
        #expect(m.nodes["C"]?.shape == .stadium)
        #expect(m.nodes["D"]?.shape == .circle)
        #expect(m.nodes["E"]?.shape == .cylinder)
        #expect(m.edges.count == 4)
        #expect(m.edges[1].label == "是")
        #expect(m.edges[2].label == "否")
        #expect(m.edges[3].style == .dashed)
    }

    @Test("链式、并列与子图")
    func chainAndSubgraph() throws {
        let m = try model("""
        graph TD
          subgraph one [第一组]
            A --> B
          end
          C & D --> A --> E
          B ==> E
        """)
        #expect(m.subs["one"]?.members == ["A", "B"])
        #expect(m.edges.count == 5)
        #expect(m.edges.last?.style == .thick)
    }

    @Test("双向与端点样式")
    func arrows() throws {
        let m = try model("graph LR\nA <--> B\nA --o C\nA --x D\nA --- E")
        #expect(m.edges[0].start == .arrow && m.edges[0].end == .arrow)
        #expect(m.edges[1].end == .circle)
        #expect(m.edges[2].end == .cross)
        #expect(m.edges[3].end == .none)
    }

    @Test("未闭合的形状抛出带行号的错误")
    func errors() {
        #expect(throws: MermaidError.self) { _ = try self.model("graph TD\nA[未闭合 --> B") }
    }
}

@Suite("Mermaid 布局")
struct MermaidLayoutTests {
    /// 断言任意两个节点矩形互不相交。
    private func assertNoOverlap(_ scene: MScene, sourceLocation: SourceLocation = #_sourceLocation) {
        let rects = Array(scene.nodeRects.values)
        for i in rects.indices { for j in rects.indices where j > i {
            #expect(!rects[i].insetBy(dx: 0.5, dy: 0.5).intersects(rects[j]), "节点重叠:\(rects[i]) 与 \(rects[j])", sourceLocation: sourceLocation)
        } }
    }

    @Test("各方向布局无重叠", arguments: ["TB", "BT", "LR", "RL"])
    func directions(_ d: String) throws {
        let scene = try Mermaid.scene(for: """
        flowchart \(d)
          A[Start] --> B{Ok?}
          B -->|yes| C[Run]
          B -->|no| D[Fix]
          C --> E[Done]
          D --> B
          A --> E
          E --> F & G & H
        """)
        #expect(scene.nodeRects.count == 8)
        assertNoOverlap(scene)
        #expect(scene.size.width > 0 && scene.size.height > 0)
    }

    @Test("TB 时子节点在父节点下方,LR 时在右侧")
    func ordering() throws {
        let tb = try Mermaid.scene(for: "graph TB\nA-->B")
        #expect((tb.nodeRects["B"]?.minY ?? 0) > (tb.nodeRects["A"]?.maxY ?? 1))
        let lr = try Mermaid.scene(for: "graph LR\nA-->B")
        #expect((lr.nodeRects["B"]?.minX ?? 0) > (lr.nodeRects["A"]?.maxX ?? 1))
        let bt = try Mermaid.scene(for: "graph BT\nA-->B")
        #expect((bt.nodeRects["B"]?.maxY ?? 1) < (bt.nodeRects["A"]?.minY ?? 0))
    }

    @Test("含环与自环不崩溃且无重叠")
    func cycles() throws {
        let scene = try Mermaid.scene(for: "graph TD\nA-->B\nB-->C\nC-->A\nA-->A\nC-->D")
        assertNoOverlap(scene)
        #expect(scene.nodeRects.count == 4)
    }

    @Test("长边跨多层仍无重叠")
    func longEdge() throws {
        let scene = try Mermaid.scene(for: "graph TD\nA-->B-->C-->D-->E\nA-->|很长的边标签|E\nB-->D")
        assertNoOverlap(scene)
    }

    @Test("子图包含其成员且互不重叠")
    func subgraphs() throws {
        let scene = try Mermaid.scene(for: """
        flowchart TB
          subgraph s1 [前端]
            A --> B
          end
          subgraph s2 [后端]
            C --> D
          end
          B --> C
          X --> A
          D --> Y
        """)
        assertNoOverlap(scene)
        let rectCount = scene.items.filter { if case .rect = $0 { return true } else { return false } }.count
        #expect(rectCount == 2)
    }

    @Test("中文与多行文本")
    func cjk() throws {
        let scene = try Mermaid.scene(for: "graph LR\nA[用户请求<br/>第二行] --> B[网关]\nB --> C[服务一] & D[服务二]")
        assertNoOverlap(scene)
        #expect((scene.nodeRects["A"]?.height ?? 0) > 40)
    }

    @Test("大图性能:200 节点链状图在合理时间内完成")
    func performance() throws {
        var src = "graph TD\n"
        for i in 0..<200 { src += "N\(i) --> N\(i + 1)\n"; if i % 5 == 0 { src += "N\(i) --> N\(i + 3)\n" } }
        let start = Date()
        let scene = try Mermaid.scene(for: src)
        #expect(Date().timeIntervalSince(start) < 5)
        assertNoOverlap(scene)
    }
}

@Suite("Mermaid 其他图类型")
struct MermaidOtherDiagramTests {
    @Test("状态图:起止点与复合状态")
    func state() throws {
        let scene = try Mermaid.scene(for: """
        stateDiagram-v2
          [*] --> Idle
          Idle --> Running : start
          state Running {
            [*] --> Step1
            Step1 --> Step2
            Step2 --> [*]
          }
          Running --> [*]
        """)
        #expect(scene.nodeRects["Idle"] != nil)
        #expect(scene.nodeRects["Step1"] != nil)
        let dots = scene.items.filter { if case .shape(let s, _, _, _, _) = $0 { return s == .startDot || s == .endDot } else { return false } }
        #expect(dots.count >= 4)
    }

    @Test("类图:成员、方法与关系")
    func classDiagram() throws {
        let scene = try Mermaid.scene(for: """
        classDiagram
          class Animal {
            +String name
            +eat() void
          }
          Animal <|-- Dog
          Animal <|-- Cat : 继承
          Dog : +bark()
          Dog *-- Tail
        """)
        #expect(scene.nodeRects.count == 4)
        let boxes = scene.items.compactMap { item -> (String, [String], [String])? in
            if case let .classCompartments(_, t, f, m) = item { return (t, f, m) } else { return nil }
        }
        let animal = boxes.first { $0.0 == "Animal" }
        #expect(animal?.1 == ["+String name"])
        #expect(animal?.2 == ["+eat() void"])
        #expect(boxes.first { $0.0 == "Dog" }?.2 == ["+bark()"])
    }

    @Test("时序图:参与者、消息、激活与分组")
    func sequence() throws {
        let m = try SequenceParser.parse(Mermaid.cleanedLines("""
        sequenceDiagram
          autonumber
          participant U as 用户
          actor S as 服务
          U->>+S: 请求
          S-->>-U: 响应
          Note over U,S: 完成
          loop 每分钟
            U->>U: 自检
          end
        """))
        #expect(m.participants.map(\.label) == ["用户", "服务"])
        #expect(m.participants[1].isActor)
        #expect(m.autonumber)
        #expect(m.events.count == 6)
        let scene = SequenceLayout.scene(for: m)
        #expect(scene.size.width > 100 && scene.size.height > 100)
        #expect(scene.nodeRects.count == 2)
        #expect((scene.nodeRects["U"]?.maxX ?? 0) < (scene.nodeRects["S"]?.minX ?? 0))
    }

    @Test("饼图:比例与图例")
    func pie() throws {
        let scene = try Mermaid.scene(for: "pie showData title 占比\n\"甲\" : 30\n\"乙\" : 70")
        let slices = scene.items.compactMap { item -> Double? in
            if case let .slice(_, _, a, b, _) = item { return b - a } else { return nil }
        }
        #expect(slices.count == 2)
        #expect(abs(slices.reduce(0, +) - 2 * .pi) < 1e-9)
        #expect(abs(slices[0] / (2 * .pi) - 0.3) < 1e-9)
    }

    @Test("甘特图:依赖与时长")
    func gantt() throws {
        let m = try GanttParser.parse(Mermaid.cleanedLines("""
        gantt
          title 计划
          dateFormat YYYY-MM-DD
          section 设计
          调研 :done, a1, 2026-01-01, 5d
          方案 :a2, after a1, 3d
          section 开发
          实现 :crit, 2026-01-10, 2026-01-20
          上线 :milestone, 2026-01-21, 0d
        """))
        #expect(m.tasks.count == 4)
        #expect(m.tasks[0].end - m.tasks[0].start == 5)
        #expect(m.tasks[1].start == m.tasks[0].end)
        #expect(m.tasks[2].crit)
        #expect(m.tasks[3].milestone)
        let scene = GanttLayout.scene(for: m)
        #expect(!scene.items.isEmpty)
    }

    @Test("不支持的类型与空内容给出明确错误")
    func unsupported() {
        #expect(throws: MermaidError.self) { _ = try Mermaid.scene(for: "erDiagram\nA ||--o{ B : has") }
        #expect(throws: MermaidError.self) { _ = try Mermaid.scene(for: "") }
    }

    @Test("YAML 头与 init 指令被忽略")
    func frontmatter() throws {
        let scene = try Mermaid.scene(for: "---\ntitle: x\n---\n%%{init: {}}%%\ngraph TD\nA-->B")
        #expect(scene.nodeRects.count == 2)
    }
}

@Suite("Mermaid 渲染")
@MainActor
struct MermaidRenderingTests {
    nonisolated static let samples: [(String, String)] = [
        ("flow", "flowchart TD\n  A[用户请求] --> B{已登录?}\n  B -->|是| C[读取数据]\n  B -->|否| D[跳转登录]\n  D --> A\n  C --> E([完成])\n  subgraph 后端\n    C --> F[(数据库)]\n  end\n  A --- G((圆)) ==> H[[子程序]]\n  H -.-> I{{六边形}}"),
        ("flow_lr", "graph LR\n  A[Client] --> B[Gateway] --> C[Service A] & D[Service B]\n  C --> E[(DB)]\n  D --> E\n  B -- 缓存 --> F>Redis]\n  E --o G[/Log/]"),
        ("sequence", "sequenceDiagram\n  autonumber\n  participant U as 用户\n  participant S as 服务\n  actor D as 数据库\n  U->>+S: 发起请求\n  S->>D: 查询\n  D-->>S: 结果\n  S-->>-U: 返回结果\n  Note over U,S: 完成\n  alt 成功\n    U->>U: 展示\n  else 失败\n    U-xS: 重试\n  end"),
        ("state", "stateDiagram-v2\n  [*] --> Idle\n  Idle --> Running : start\n  state Running {\n    [*] --> Step1\n    Step1 --> Step2\n    Step2 --> [*]\n  }\n  Running --> Idle : stop\n  Running --> [*]"),
        ("class", "classDiagram\n  class Animal {\n    +String name\n    +eat() void\n  }\n  Animal <|-- Dog\n  Animal <|-- Cat : 继承\n  Dog : +bark()\n  Dog *-- Tail\n  Cat o-- Toy\n  Dog ..> Food : eats"),
        ("pie", "pie showData title 占比\n  \"甲\" : 30\n  \"乙\" : 50\n  \"丙\" : 20"),
        ("gantt", "gantt\n  title 计划\n  dateFormat YYYY-MM-DD\n  section 设计\n  调研 :done, a1, 2026-01-01, 5d\n  方案 :a2, after a1, 3d\n  section 开发\n  实现 :crit, 2026-01-10, 2026-01-20\n  上线 :milestone, 2026-01-21, 0d"),
    ]

    @Test("每种图都能渲染出非空 PNG", arguments: samples.map(\.0))
    func png(_ name: String) throws {
        let source = try #require(Self.samples.first { $0.0 == name }?.1)
        let scene = try Mermaid.scene(for: source)
        let data = try #require(MermaidRenderer.pngData(scene, dark: false))
        #expect(data.count > 1000)
        #expect(data.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        if let dir = ProcessInfo.processInfo.environment["MM_DUMP"] {
            try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("mm_\(name).png"))
            if let dark = MermaidRenderer.pngData(scene, dark: true) { try dark.write(to: URL(fileURLWithPath: dir).appendingPathComponent("mm_\(name)_dark.png")) }
        }
    }
}
