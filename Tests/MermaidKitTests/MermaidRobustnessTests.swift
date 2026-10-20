// @author ixxxxoooo
// MermaidKit 健壮性测试:图类型识别、注释处理与畸形输入不崩溃。

import Foundation
import Testing
@testable import MermaidKit

@Suite("Mermaid 图类型识别与健壮性")
struct MermaidRobustnessTests {
    @Test("各类型声明被正确识别(忽略大小写与前导注释)", arguments: [
        ("graph TD\nA-->B", MermaidKind.flowchart),
        ("flowchart LR\nA-->B", .flowchart),
        ("%% 注释\nstateDiagram-v2\n[*] --> A", .state),
        ("classDiagram\nclass A", .classDiagram),
        ("sequenceDiagram\nA->>B: hi", .sequence),
        ("pie\n\"a\" : 1", .pie),
        ("gantt\ntitle t", .gantt),
    ])
    func kinds(_ source: String, _ expected: MermaidKind) throws {
        #expect(try Mermaid.kind(of: source) == expected)
    }

    @Test("只有注释与空白的内容视为空,抛出错误")
    func blankContent() {
        #expect(throws: MermaidError.self) { _ = try Mermaid.kind(of: "%% 只有注释\n\n   \n") }
    }

    @Test("CRLF 换行与 init 指令不影响解析")
    func crlf() throws {
        let scene = try Mermaid.scene(for: "%%{init: {}}%%\r\ngraph TD\r\nA-->B\r\n")
        #expect(!scene.items.isEmpty)
    }

    @Test("畸形输入只抛错误、不崩溃", arguments: [
        "graph TD\nA[未闭合",
        "graph TD\nA-->",
        "graph TD\nsubgraph\nA",
        "sequenceDiagram\n->>: ",
        "pie\n\"a\" : abc",
        "gantt\nsection\n  : :",
        "classDiagram\nA <|-- ",
        "stateDiagram-v2\n--> -->",
    ])
    func malformed(_ source: String) {
        // 允许成功或抛 MermaidError,但不能崩溃
        do { _ = try Mermaid.scene(for: source) } catch is MermaidError {} catch { Issue.record("未预期的错误类型:\(error)") }
    }
}
