// @author ygw
// 演示场景目录:注册全部 `#demo-<场景名>`。

import Foundation

extension DemoScenarios {
    /// 全部演示场景(顺序即命令面板/斜杠补全的展示顺序)。
    static let catalogScenarios: [DemoScenario] = {
        var list: [DemoScenario] = [
            DemoScenario(id: "tools-files", group: "工具卡", title: "文件工具", summary: "查找/读取(含超长输出)/搜索/新建/编辑/多处编辑/Notebook/删除/移动", build: toolsFiles),
            DemoScenario(id: "tools-shell", group: "工具卡", title: "终端工具", summary: "ANSI 输出、超长输出、失败、多行命令、后台命令", build: toolsShell),
            DemoScenario(id: "tools-web-mcp", group: "工具卡", title: "联网与 MCP", summary: "WebSearch、WebFetch、多个 MCP 服务器,含失败", build: toolsWebMcp),
            DemoScenario(id: "tools-plan-todo", group: "工具卡", title: "待办与计划", summary: "TodoWrite、计划条目推进、思考、模式切换", build: toolsPlanTodo),
            DemoScenario(id: "permissions", group: "交互", title: "权限请求", summary: "Diff 预览、Bash 命令、始终允许、拒绝(交互)", behavior: .interactive, build: permissions),
            DemoScenario(id: "plan-approval", group: "交互", title: "计划批准", summary: "ExitPlanMode 计划卡与批准后的计划文档(交互)", behavior: .interactive, build: planApproval),
            DemoScenario(id: "ask", group: "交互", title: "提问向导", summary: "AskUserQuestion 逐题向导(交互)", behavior: .interactive, build: ask),
            DemoScenario(id: "changes", group: "交互", title: "本轮改动", summary: "真实修改 oma-demo.txt,生成「改动」汇总与回退(交互)", behavior: .interactive, build: changes),
            DemoScenario(id: "markdown", group: "样式", title: "Markdown 与代码高亮", summary: "标题/列表/表格/引用/多语言代码块", build: markdown),
            DemoScenario(id: "mermaid", group: "样式", title: "Mermaid 图", summary: "流程/时序/状态/类/饼图/甘特与不支持类型回退", build: mermaid),
        ]
        list.append(contentsOf: agentScenarios)
        return list
    }()
}
