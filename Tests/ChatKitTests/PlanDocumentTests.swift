// @author ixxxxoooo
// 计划文件测试:标题/概述/待办解析、文件名、YAML 头往返、全局与工作区目录读写。

import Foundation
import Testing
@testable import ChatKit

@Suite("计划文件")
struct PlanDocumentTests {
    static let sample = """
    # 修复路由大小写匹配

    路由用请求路径直接当字典 key,所以大小写与末尾斜杠都会失配。

    ## 实施步骤

    1. 新增 `Router.normalize`
    2. `route` 与 `register` 统一使用
    3. 补充回归测试

    ## 风险

    1. 已有路由可能被改成小写
    """

    @Test("解析标题、概述与「步骤」标题下的编号待办")
    func parseSample() {
        let plan = PlanDocument.parse(markdown: Self.sample)
        #expect(plan.name == "修复路由大小写匹配")
        #expect(plan.overview.hasPrefix("路由用请求路径"))
        #expect(plan.todos.map(\.content) == ["新增 `Router.normalize`", "`route` 与 `register` 统一使用", "补充回归测试"])
        #expect(plan.todos.allSatisfy { $0.status == "pending" })
    }

    @Test("有复选项时以复选项为待办并保留完成状态")
    func parseCheckboxes() {
        let plan = PlanDocument.parse(markdown: "# 计划\n\n- [x] 梳理\n- [ ] 实现\n- [ ] 测试\n")
        #expect(plan.todos.map(\.status) == ["completed", "pending", "pending"])
        #expect(plan.completedCount == 1)
    }

    @Test("没有标题时取首行,空文本回退为「计划」")
    func parseFallbacks() {
        #expect(PlanDocument.parse(markdown: "先把缓存层抽出来\n再改调用方").name == "先把缓存层抽出来")
        #expect(PlanDocument.parse(markdown: "").name == String(localized: "计划"))
    }

    @Test("文件名由标题 slug 与内容哈希组成,同内容同名字")
    func fileName() {
        let plan = PlanDocument.parse(markdown: Self.sample)
        #expect(plan.fileName.hasPrefix("修复路由大小写匹配_"))
        #expect(plan.fileName.hasSuffix(".plan.md"))
        #expect(plan.fileName == PlanDocument.parse(markdown: Self.sample).fileName)
        #expect(PlanDocument.parse(markdown: "# a/b:c *d*\n").fileName.hasPrefix("a-b-c-d_"))
        #expect(PlanDocument.slug("!!!") == "plan")
    }

    @Test("文件内容带 YAML 头,重新解析能还原待办与状态")
    func roundTrip() {
        var plan = PlanDocument.parse(markdown: Self.sample)
        plan.todos[0].status = "completed"
        plan.todos[1].status = "in_progress"
        let text = plan.fileContents()
        #expect(text.hasPrefix("---\nname: \"修复路由大小写匹配\""))
        let again = PlanDocument.parse(markdown: text)
        #expect(again.name == plan.name)
        #expect(again.todos == plan.todos)
        #expect(again.body == plan.body)
    }

    @Test("含引号的待办往返不丢字符")
    func quoting() {
        let plan = PlanDocument(name: "带\"引号\"的标题", overview: "概述", todos: [PlanTodo(id: "t1", content: "把 \"a\" 改成 b")], body: "# x")
        let again = PlanDocument.parse(markdown: plan.fileContents())
        #expect(again.name == plan.name)
        #expect(again.todos.first?.content == "把 \"a\" 改成 b")
    }

    @Test("写入与读取:全局目录与工作区目录")
    func saveAndRead() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oma-plan-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let plan = PlanDocument.parse(markdown: Self.sample)
        let url = try PlanStore.save(plan, in: root.appendingPathComponent("global"))
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(try PlanStore.read(url).todos.count == 3)
        let workspace = PlanStore.workspaceDirectory(root.path)
        #expect(workspace.path.hasSuffix("/.oma/plans"))
        let saved = try PlanStore.save(plan, in: workspace)
        #expect(saved.lastPathComponent == plan.fileName)
    }
}
