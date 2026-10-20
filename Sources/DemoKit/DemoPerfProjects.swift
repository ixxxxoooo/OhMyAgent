// @author ixxxxoooo
// 性能实验室演示项目:三个按主题分开的复杂项目,用来在演示模式下直接测出小场景测不出的性能问题。
// - perf-longchat:超长会话(上千轮)的滚动、加载、复制;
// - perf-render:Markdown / 表格 / 图表 / Mermaid / 大 Diff 的渲染;
// - perf-multitab:多标签页 + 1 万文件的深层目录(`perf-fs`)+ 多会话并存。
// 内容全部确定性生成(无随机),同样的版本永远得到同样的文件。

import Foundation

/// 性能实验室项目生成器。
enum DemoPerfProjects {
    /// 深层目录的文件总数(10 × 10 × 10 × 10)。
    static let deepFileCount = 10_000

    // MARK: 入口

    /// 生成 `perf-longchat`:一个小而真实的 Swift 包,供长会话里的工具卡引用。
    static func buildLongChat(paths: DemoPaths) throws {
        let dir = paths.project("perf-longchat")
        try write(dir, "README.md", longChatReadme)
        try write(dir, "Package.swift", "// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: \"LongChat\", targets: [.target(name: \"LongChat\")])\n")
        for index in 1...6 {
            try write(dir, "Sources/LongChat/Module\(index).swift", swiftSource(module: "Module\(index)", functions: 40))
        }
    }

    /// 生成 `perf-render`:渲染实验室的素材(大 Markdown、大 CSV、图表源、Mermaid 源、图片)。
    static func buildRender(paths: DemoPaths) throws {
        let dir = paths.project("perf-render")
        try write(dir, "README.md", renderReadme)
        try write(dir, "docs/render-lab.md", renderLabMarkdown)
        try write(dir, "docs/flow.mmd", mermaidFlow)
        try write(dir, "data/metrics.csv", metricsCSV(rows: 3_000))
        try write(dir, "data/wide.csv", wideCSV(rows: 400, columns: 24))
        try write(dir, "src/Large.swift", swiftSource(module: "Large", functions: 600))
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("assets"), withIntermediateDirectories: true)
        try DemoImage.logoPNG().write(to: dir.appendingPathComponent("assets/logo.png"), options: .atomic)
    }

    /// 生成 `perf-multitab`:多标签素材 + Git 历史(供 diff/history/blame 标签)+ 1 万文件的 `perf-fs`。
    static func buildMultiTab(paths: DemoPaths) async throws {
        let b = DemoRepoBuilder(directory: paths.project("perf-multitab"), home: paths.home)
        try await b.initialize()
        try b.write(".gitignore", ".build/\n")
        try b.write("README.md", multiTabReadme)
        try b.write("src/Engine.swift", swiftSource(module: "Engine", functions: 300))
        try b.write("src/Router.swift", swiftSource(module: "Router", functions: 80))
        try b.write("docs/guide.md", guideV1)
        try b.write("data/sales.csv", metricsCSV(rows: 500))
        try b.write("config/app.json", configJSON)
        try await b.commit("chore: 初始化多标签实验室", by: .wen, at: DemoGit.date(day: 0))
        try b.write("src/Router.swift", swiftSource(module: "Router", functions: 90))
        try b.write("docs/guide.md", guideV2)
        try await b.commit("feat: 扩充路由与指南", by: .chen, at: DemoGit.date(day: 1))
        try b.write("src/Engine.swift", swiftSource(module: "Engine", functions: 320))
        try await b.commit("perf: 引擎热点函数拆分", by: .lin, at: DemoGit.date(day: 2))
        // 工作区未提交改动:diff 标签有内容可看
        try b.write("docs/guide.md", guideV2 + "\n## 新增章节\n\n- [ ] 待补充的内容\n")
        // 深层目录放在提交之后(保持未跟踪,git 只把它当一个目录条目,状态依旧很快)
        try buildDeepTree(root: paths.project("perf-multitab").appendingPathComponent("perf-fs", isDirectory: true))
    }

    // MARK: 深层目录

    /// 生成 `d0…d9 / d0…d9 / d0…d9` 三层、每个叶目录 10 个文件,共 1 万个文件。
    /// - Parameter root: 深层目录根(`perf-fs`)
    static func buildDeepTree(root: URL) throws {
        let fileManager = FileManager.default
        let extensions = ["swift", "md", "json", "txt", "ts"]
        for a in 0..<10 {
            for b in 0..<10 {
                for c in 0..<10 {
                    let dir = root.appendingPathComponent("group\(a)/module\(b)/part\(c)", isDirectory: true)
                    try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
                    for d in 0..<10 {
                        let ext = extensions[(a + b + c + d) % extensions.count]
                        let body = "// perf-fs/group\(a)/module\(b)/part\(c)/file\(d).\(ext)\n"
                        let url = dir.appendingPathComponent("file\(d).\(ext)")
                        guard fileManager.createFile(atPath: url.path, contents: Data(body.utf8)) else {
                            throw DemoError.ioFailed("写入 \(url.path) 失败")
                        }
                    }
                }
            }
        }
    }

    // MARK: 内容生成

    private static func write(_ dir: URL, _ relative: String, _ text: String) throws {
        let url = dir.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// 确定性的 Swift 源码(每个函数 6 行,便于造出长文件)。
    static func swiftSource(module: String, functions: Int) -> String {
        let body = (1...max(functions, 1)).map { index in
            """
            /// \(module) 第 \(index) 个函数:演示用的确定性代码。
            func \(module.lowercased())Handler\(index)(_ request: Request, retries: Int = \(index % 5)) async throws -> Response {
                guard request.path.hasPrefix("/api/v\(index % 3 + 1)") else { return .notFound }
                let payload = try await load(\(index), timeout: .seconds(\(index % 30 + 1)))
                return .ok(payload.map { $0.uppercased() }.joined(separator: ","))
            }
            """
        }.joined(separator: "\n\n")
        return "// @author ixxxxoooo\n// \(module):性能实验室素材。\n\nimport Foundation\n\n" + body + "\n"
    }

    /// 指标 CSV(日期、区域、产品、销量、金额)。
    static func metricsCSV(rows: Int) -> String {
        let regions = ["华东", "华北", "华南", "西南", "东北"]
        let products = ["Atlas", "Beacon", "Cobalt", "Delta"]
        var lines = ["date,region,product,units,amount"]
        for index in 0..<rows {
            let day = index % 28 + 1
            lines.append("2026-09-\(String(format: "%02d", day)),\(regions[index % 5]),\(products[index % 4]),\(index * 7 % 113 + 1),\(Double(index * 31 % 9_973) / 10 + 10)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// 宽表 CSV(列很多,测横向滚动)。
    static func wideCSV(rows: Int, columns: Int) -> String {
        let header = (1...columns).map { "col\($0)" }.joined(separator: ",")
        let body = (0..<rows).map { row in (1...columns).map { "\(row * $0 % 997)" }.joined(separator: ",") }
        return ([header] + body).joined(separator: "\n") + "\n"
    }

    static let longChatReadme = """
    # perf-longchat

    演示模式「性能实验室 · 超长会话」项目。左侧会话列表里的每条会话标题都以 `[性能]` 开头并写明测什么:

    - 2000 轮长会话:滚动、加载、跨叶子复制;
    - 800 轮混合内容:代码块、表格、图表、Mermaid 穿插;
    - 单轮超长输出:2000 行终端与大 Diff。

    直接点开会话即可,不需要输入任何命令。

    """

    static let renderReadme = """
    # perf-render

    演示模式「性能实验室 · 渲染」项目:Markdown、宽表格、折线/K 线图、Mermaid 全图种、大 Diff 与多语言代码块。
    `docs/render-lab.md` 是一份用于所见即所得编辑与阅读的大文档;`data/*.csv` 用于表格预览。

    """

    static let multiTabReadme = """
    # perf-multitab

    演示模式「性能实验室 · 多标签」项目。启动时已预置:多个会话标签、源码/文档/CSV/配置标签、改动对比、提交历史与 blame。
    `perf-fs/` 里有 1 万个文件(3 层目录),用来测资源管理器展开、搜索与文件监听。

    """

    static let guideV1 = """
    # 使用指南

    ## 快速开始

    - [x] 安装依赖
    - [ ] 运行示例
    - [ ] 阅读架构文档

    更多说明见 [官网](https://example.com)。

    """

    static let guideV2 = guideV1 + """

    ## 进阶

    1. 配置 `config/app.json`
    2. 打开多标签工作区
    3. 在「编辑」模式下直接点击任务框勾选,回车自动续写列表

    > 所见即所得:标题、**加粗**、`行内代码` 都就地渲染。

    """

    static let configJSON = "{\n  \"name\": \"perf-multitab\",\n  \"workers\": 8,\n  \"features\": [\"tabs\", \"search\", \"watch\"],\n  \"limits\": { \"files\": 10000, \"depth\": 4 }\n}\n"

    static let mermaidFlow = "flowchart TD\n  A[开始] --> B{检查}\n  B -->|通过| C[构建]\n  B -->|失败| D[修复]\n  D --> B\n  C --> E([发布])\n"

    /// 渲染实验室大文档:多级标题、任务列表、宽表格、多语言代码块、Mermaid、引用与嵌套列表。
    static var renderLabMarkdown: String {
        let rows = (1...60).map { "| 模块 \($0) | \($0 * 13 % 97) | \(Double($0 * 37 % 1000) / 10)% | 第 \($0) 行的说明文字,用来撑出较长的单元格内容 |" }
        let table = (["| 模块 | 数量 | 占比 | 说明 |", "| --- | ---: | ---: | --- |"] + rows).joined(separator: "\n")
        let sections = (1...12).map { index in
            "## 第 \(index) 节\n\n这是第 \(index) 节的正文,包含 **加粗**、*斜体*、~~删除线~~ 与 `行内代码`,以及一个链接 [示例](https://example.com/\(index))。\n\n- [ ] 第 \(index) 节待办 A\n- [x] 第 \(index) 节待办 B\n  - 嵌套项 \(index).1\n  - 嵌套项 \(index).2\n"
        }.joined(separator: "\n")
        return "# 渲染实验室\n\n\(sections)\n## 宽表格\n\n\(table)\n\n## 代码\n\n```swift\n\(swiftSource(module: "Lab", functions: 6))\n```\n\n## 图\n\n```mermaid\n\(mermaidFlow)```\n\n> 引用:所见即所得编辑下,光标进入的块还原为源码。\n"
    }
}
