// @author ixxxxoooo
// 演示场景目录:注册全部 `#demo-<场景名>`。

import Foundation

extension DemoScenarios {
    /// 全部演示场景(顺序即命令面板/斜杠补全的展示顺序)。
    static let catalogScenarios: [DemoScenario] = {
        var list: [DemoScenario] = [
            DemoScenario(id: "showcase-tour", group: "全景", title: "完整修复一个 Bug:路由大小写匹配", summary: "一条自动流程里同屏出现:提问、思考、浏览、待办、编辑 Diff、测试失败后再修复、子 Agent 审查、Markdown 总结与用量", build: showcaseTour),
            DemoScenario(id: "tools-files", group: "工具卡", title: "文件读写:梳理并整理路由层", summary: "查找/读取(含超长输出)/搜索/新建/编辑/多处编辑/Notebook/删除/移动", build: toolsFiles),
            DemoScenario(id: "tools-shell", group: "工具卡", title: "终端:构建、测试与后台服务", summary: "ANSI 彩色输出、超长输出、失败退出码、多行命令、后台命令", build: toolsShell),
            DemoScenario(id: "tools-web-mcp", group: "工具卡", title: "联网与 MCP:调研迁移指南并核对 PR", summary: "WebSearch、WebFetch、GitHub/Playwright/filesystem 等 MCP 服务器,含失败", build: toolsWebMcp),
            DemoScenario(id: "canvas", group: "工具卡", title: "画布:生成季度质量周报", summary: "canvas_create / canvas_update 与时间线里的画布卡片", build: canvasTools),
            DemoScenario(id: "tools-browser", group: "工具卡", title: "内置浏览器:排查指标看板报错", summary: "browser_* 全套:导航/快照/输入/点击/滚动/截图(图片结果)/控制台/网络/标签页", build: browserTools),
            DemoScenario(id: "tools-image", group: "工具卡", title: "读取图片:查看图标与报错截图", summary: "Read 返回图片内容块,工具卡里显示可点击放大的缩略图", build: imageTools),
            DemoScenario(id: "tools-plan-todo", group: "工具卡", title: "待办与计划:拆解指标上报任务", summary: "TodoWrite 逐项推进、计划条目、Think 思考、模式切换", build: toolsPlanTodo),
            DemoScenario(id: "permissions", group: "交互", title: "权限请求:修改配置与执行命令", summary: "Diff 预览、Bash 命令、始终允许、拒绝(交互)", behavior: .interactive, build: permissions),
            DemoScenario(id: "plan-approval", group: "交互", title: "计划批准:迁移遗留接口", summary: "ExitPlanMode 计划卡、三种批准方式与批准后的计划文档(交互)", behavior: .interactive, build: planApproval),
            DemoScenario(id: "ask", group: "交互", title: "提问向导:确认技术选型", summary: "AskUserQuestion 逐题向导:单选/多选/自定义(交互)", behavior: .interactive, build: ask),
            DemoScenario(id: "changes", group: "交互", title: "本轮改动:检查点与一键回退", summary: "真实修改 oma-demo.txt,生成「改动」汇总并可回退(交互)", behavior: .interactive, build: changes),
            DemoScenario(id: "markdown", group: "会话流样式", title: "Markdown 与代码高亮:发布说明", summary: "标题/列表/任务列表/表格/引用/多语言代码块", build: markdown),
            DemoScenario(id: "mermaid", group: "会话流样式", title: "Mermaid 图表:架构文档", summary: "流程/时序/状态/类/饼图/甘特与不支持类型的回退", build: mermaid),
            DemoScenario(id: "user-variants", group: "会话流样式", title: "用户消息:图片、@文件与长文折叠", summary: "带图片、@文件文本、超过 6 行自动折叠、纯图片、多图、原样 Markdown、中英混排", build: userVariants),
            DemoScenario(id: "markdown-edge", group: "会话流样式", title: "Markdown 边界:嵌套、宽表格与回退", summary: "多级嵌套列表、引用含列表、宽表格、更多围栏语言、公式/图片/HTML 的回退、超长单词、未闭合围栏", build: markdownEdge),
        ]
        list.append(contentsOf: agentScenarios)
        list.append(contentsOf: endingScenarios)
        list.append(contentsOf: usageScenarios)
        list.append(contentsOf: modeScenarios)
        list.append(contentsOf: permissionScenarios)
        list.append(contentsOf: askScenarios)
        list.append(contentsOf: lifecycleScenarios)
        list.append(contentsOf: tickerScenarios)
        return list
    }()
}
