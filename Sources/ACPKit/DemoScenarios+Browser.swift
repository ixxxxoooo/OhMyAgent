// @author ixxxxoooo
// 演示场景:内置浏览器的 Bridge 工具(导航/快照/点击/输入/滚动/截图/控制台/网络/标签页)与读取图片文件;
// 截图与图片以 `image` 内容块返回,工具卡里显示为可点击放大的缩略图。

import Foundation

extension DemoScenarios {
    /// 浏览器工具全套:导航 → 快照 → 点击 → 输入 → 滚动 → 截图 → 控制台 → 网络 → 标签页。
    static func browserTools(_ c: ScenarioContext) -> [ScenarioStep] {
        func tool(_ id: String, _ name: String, _ input: JSONValue = .object([:]), output: String, extra: [JSONValue] = [], finish: ScenarioFinish = .completed) -> ScenarioStep {
            .tool(ScenarioTool(id: id, title: "mcp__ohmyagent__" + name, kind: "other", name: "mcp__ohmyagent__" + name, input: input, output: output, extra: extra, finish: finish))
        }
        let snapshot = """
        - document "Atlas · 指标看板" [ref=e1]
          - navigation "主导航" [ref=e2]
            - link "概览" [ref=e3] href=/overview
            - link "指标" [ref=e4] href=/metrics
            - link "发布" [ref=e5] href=/releases
          - main [ref=e6]
            - heading "请求指标" [ref=e7]
            - textbox "搜索路由" [ref=e8]
            - button "刷新" [ref=e9]
            - table "最近 24 小时" [ref=e10]
        """
        return DemoSteps.withUsage([
            DemoSteps.say("我先用内置浏览器打开本地开发服务,看看指标看板的实际表现。\n\n"),
            tool("b_nav", "browser_navigate", ["url": "http://localhost:5173/metrics"],
                 output: "Opened http://localhost:5173/metrics — title: Atlas · 指标看板\nTake a browser_snapshot to see the page."),
            tool("b_snap", "browser_snapshot", output: snapshot),
            tool("b_type", "browser_type", ["ref": "e8", "text": "/api/users", "submit": true],
                 output: "Typed into textbox \"搜索路由\". Now at http://localhost:5173/metrics?q=%2Fapi%2Fusers"),
            tool("b_click", "browser_click", ["ref": "e9"],
                 output: "Clicked button \"刷新\". Now at http://localhost:5173/metrics?q=%2Fapi%2Fusers — Atlas · 指标看板"),
            tool("b_hover", "browser_hover", ["ref": "e4"], output: "Hovered link \"指标\""),
            tool("b_dbl", "browser_click", ["ref": "e7", "double": true], output: "Double-clicked heading \"请求指标\". Now at http://localhost:5173/metrics?q=%2Fapi%2Fusers — Atlas · 指标看板"),
            tool("b_scroll", "browser_scroll", ["direction": "bottom"], output: "Scrolled to the bottom (y=1184 of 1184)."),
            tool("b_shot", "browser_screenshot", output: "Screenshot of http://localhost:5173/metrics?q=%2Fapi%2Fusers",
                 extra: [["type": "content", "content": ScenarioImages.contentBlock(.dashboard)]]),
            tool("b_console", "browser_console",
                 output: "[log] [vite] connected.\n[warning] Each child in a list should have a unique \"key\" prop.\n[error] Uncaught TypeError: Cannot read properties of undefined (reading 'p95')\n    at MetricsTable (MetricsTable.tsx:42:18)"),
            tool("b_net", "browser_network",
                 output: "GET http://localhost:5173/metrics → 200 (38 ms)\nGET http://localhost:5173/api/metrics?route=%2Fapi%2Fusers → 200 (212 ms)\nGET http://localhost:5173/api/metrics/latency?route=%2Fapi%2Fusers → 500 (96 ms)\nGET https://fonts.gstatic.com/s/inter/v13/inter.woff2 → 200 (141 ms)"),
            tool("b_net2", "browser_network", ["request": 3],
                 output: "#3 GET http://localhost:5173/api/metrics/latency?route=%2Fapi%2Fusers\nStatus: 500 (96 ms)\nContent-Type: application/json\nRequest body: (none)\nResponse body: {\"error\":\"latency window is empty\",\"route\":\"/api/users\"}"),
            tool("b_back", "browser_back", output: "Went back to http://localhost:5173/metrics — title: Atlas · 指标看板"),
            tool("b_tabs", "browser_tabs", output: "browser-1 (current): Atlas · 指标看板 — http://localhost:5173/metrics?q=%2Fapi%2Fusers\nbrowser-2: Vite — http://localhost:5173/"),
            DemoSteps.say("""
            页面能打开,但**延迟表格渲染报错**:`/api/metrics/latency` 返回 500,前端又没有处理空数据,于是在 `MetricsTable.tsx:42` 读取 `p95` 时崩溃。
            建议先在组件里给空数据兜底,再去查后端 `latency` 接口为什么返回 500。
            """),
        ], used: 61_300)
    }

    /// 读取图片文件:Read 返回 image 内容块。
    static func imageTools(_ c: ScenarioContext) -> [ScenarioStep] {
        DemoSteps.withUsage([
            DemoSteps.say("我先看一下仓库里的图标资源。\n\n"),
            .tool(ScenarioTool(id: "i_read", title: "读取 logo.png", kind: "read", name: "Read",
                               input: ["file_path": DemoSteps.path(c, "assets/logo.png")],
                               extra: [["type": "content", "content": ScenarioImages.contentBlock(.logo)]],
                               locations: [["path": DemoSteps.path(c, "assets/logo.png")]])),
            .tool(ScenarioTool(id: "i_read2", title: "读取 error-page.png", kind: "read", name: "Read",
                               input: ["file_path": DemoSteps.path(c, "docs/error-page.png")],
                               extra: [["type": "content", "content": ScenarioImages.contentBlock(.errorPage)]],
                               locations: [["path": DemoSteps.path(c, "docs/error-page.png")]])),
            DemoSteps.say("`logo.png` 是 256×256 的圆角渐变徽标;`error-page.png` 是一张报错页截图:顶部红色告警条,下方是一段堆栈输出。\n"),
        ], used: 24_100)
    }
}
