// @author ixxxxoooo
// 演示项目生成器:在沙盒里确定性地生成多个演示项目与完整的 Git 仓库。
// 固定作者与时间,同样的输入永远得到同样的提交历史。

import CoreGraphics
import Foundation
import ImageIO
import OMLog
import UniformTypeIdentifiers

/// 一个演示项目的描述。
public struct DemoProjectInfo: Sendable, Equatable {
    /// 项目目录名
    public let name: String
    /// 项目绝对路径
    public let path: String
    /// 是否为 Git 仓库
    public let isGitRepository: Bool
    /// 一句话说明(演示什么)
    public let summary: String
}

/// 演示项目生成入口。
public enum DemoWorkspace {
    /// 数据版本:改动生成内容时递增,旧沙盒会被自动重建。
    public static let dataVersion = "2"

    /// 全部演示项目(顺序即项目树里的默认顺序)。
    public static let catalog: [(name: String, git: Bool, summary: String)] = [
        ("atlas-web", true, "主演示项目:25+ 提交、多分支、合并、标签、2 个 stash、领先远端、各类工作区改动"),
        ("notes-cli", true, "干净的小仓库:无改动状态"),
        ("merge-lab", true, "合并冲突中:两个文件冲突"),
        ("legacy-api", false, "非 Git 目录:验证「不是仓库」空态"),
        ("empty-project", false, "空目录"),
        ("perf-longchat", false, "性能实验室·超长会话:上千轮会话的滚动、加载、跨叶子复制与混合内容"),
        ("perf-render", false, "性能实验室·渲染:大 Markdown、宽表格、图表、Mermaid 全图种、大 Diff"),
        ("perf-multitab", true, "性能实验室·多标签:预置多会话/文件/对比/历史标签 + 1 万文件深层目录 perf-fs"),
    ]

    /// 生成(或复用)演示项目。
    /// - Parameters:
    ///   - paths: 沙盒路径
    ///   - reset: 为 true 时无条件重建
    /// - Returns: 项目列表(含路径)
    public static func materialize(paths: DemoPaths, reset: Bool = false) async throws -> [DemoProjectInfo] {
        let fileManager = FileManager.default
        let upToDate = (try? String(contentsOf: paths.marker, encoding: .utf8)) == dataVersion
        if !reset, upToDate, catalog.allSatisfy({ fileManager.fileExists(atPath: paths.project($0.name).path) }) {
            return infos(paths: paths)
        }
        let started = ContinuousClock.now
        try? fileManager.removeItem(at: paths.root)
        for directory in [paths.projects, paths.remotes, paths.home, paths.support] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try fileManager.createDirectory(at: paths.project("empty-project"), withIntermediateDirectories: true)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await buildAtlas(paths: paths) }
            group.addTask { try await buildNotes(paths: paths) }
            group.addTask { try await buildMergeLab(paths: paths) }
            group.addTask { try buildLegacy(paths: paths) }
            group.addTask { try DemoPerfProjects.buildLongChat(paths: paths) }
            group.addTask { try DemoPerfProjects.buildRender(paths: paths) }
            group.addTask { try await DemoPerfProjects.buildMultiTab(paths: paths) }
            try await group.waitForAll()
        }
        try dataVersion.write(to: paths.marker, atomically: true, encoding: .utf8)
        Log.app.info("演示项目已生成", ["root": paths.root.path, "耗时": "\(started.duration(to: .now))"])
        return infos(paths: paths)
    }

    /// 项目描述列表。
    public static func infos(paths: DemoPaths) -> [DemoProjectInfo] {
        catalog.map { DemoProjectInfo(name: $0.name, path: paths.project($0.name).path, isGitRepository: $0.git, summary: $0.summary) }
    }

    // MARK: atlas-web

    /// 主演示项目:线性历史 + 指标分支(已合并)+ 大小写修复分支 + UI 分支 + 标签 + 远端 + stash + 工作区改动。
    static func buildAtlas(paths: DemoPaths) async throws {
        let b = DemoRepoBuilder(directory: paths.project("atlas-web"), home: paths.home)
        try await b.initialize()
        typealias F = AtlasFiles

        try b.write(".gitignore", F.gitignore); try b.write("Package.swift", F.packageSwift)
        try b.write("README.md", F.readmeV1); try b.write("Sources/AtlasCore/Router.swift", F.routerV1)
        try b.write("Sources/AtlasCore/Util.swift", F.utilV1)
        try await b.commit("chore: 初始化工程", by: .lin, at: DemoGit.date(day: 0))

        try b.write("Sources/AtlasCore/Models.swift", F.models); try b.write("Sources/AtlasCore/Router.swift", F.routerV2)
        try await b.commit("feat: 路由注册与分发", by: .lin, at: DemoGit.date(day: 1))

        try b.write("Sources/AtlasCore/Session.swift", F.sessionV1); try b.write("Sources/AtlasCore/Legacy.swift", F.legacy)
        try await b.commit("feat: 会话管理与旧版兼容层", by: .chen, at: DemoGit.date(day: 2))

        try b.write("Tests/AtlasCoreTests/RouterTests.swift", F.routerTests)
        try await b.commit("test: 路由单元测试", by: .chen, at: DemoGit.date(day: 3))

        try b.write("Sources/AtlasCore/Cache.swift", F.cacheV1)
        try await b.commit("feat: 内存缓存", by: .lin, at: DemoGit.date(day: 4))

        try b.write("docs/architecture.md", F.architectureV1)
        try await b.commit("docs: 架构说明", by: .wen, at: DemoGit.date(day: 5))
        try await b.tag("v0.1.0", message: "首个可用版本", by: .wen, at: DemoGit.date(day: 5, hour: 1))

        try b.write("web/package.json", F.packageJson); try b.write("web/src/app.ts", F.appTs); try b.write("web/src/api.ts", F.apiV1)
        try await b.commit("feat: Web 前端骨架", by: .chen, at: DemoGit.date(day: 6))

        try b.write("web/src/components/Header.tsx", F.headerV1)
        try await b.commit("feat: 页头组件", by: .wen, at: DemoGit.date(day: 7))

        try b.write("Sources/AtlasCore/Cache.swift", F.cacheV2)
        try await b.commit("fix: 缓存过期时间边界", by: .lin, at: DemoGit.date(day: 8))

        try b.write("Sources/AtlasCore/Util.swift", F.utilV2)
        try await b.commit("refactor: 抽取字节格式化工具", by: .lin, at: DemoGit.date(day: 9))

        try b.write("Sources/AtlasCore/Session.swift", F.sessionV2)
        try await b.commit("feat: 会话持久化", by: .chen, at: DemoGit.date(day: 10))

        try b.write("docs/architecture.md", F.architectureV2)
        try await b.commit("docs: 补充 Mermaid 时序图与状态图", by: .wen, at: DemoGit.date(day: 11))
        try await b.tag("v0.2.0", message: "会话与文档", by: .wen, at: DemoGit.date(day: 11, hour: 1))

        try b.write("web/src/api.ts", F.apiV2)
        try await b.commit("feat: API 错误码", by: .chen, at: DemoGit.date(day: 12))

        try b.write("Sources/AtlasCore/Router.swift", F.routerV3)
        try await b.commit("perf: 路由查找改为字典", by: .lin, at: DemoGit.date(day: 13))

        // 指标分支(最终合并回 main)
        try await b.git(["checkout", "-q", "-b", "feature/metrics"])
        try b.write("Sources/AtlasCore/Metrics.swift", F.metrics)
        try await b.commit("feat: 新增 Metrics 计数器", by: .lin, at: DemoGit.date(day: 14))
        try b.write("Sources/AtlasCore/Router.swift", F.routerMetrics)
        try await b.commit("feat: Router 记录未命中次数", by: .lin, at: DemoGit.date(day: 14, hour: 3))
        try b.write("Tests/AtlasCoreTests/MetricsTests.swift", F.metricsTests)
        try await b.commit("test: 指标计数测试", by: .chen, at: DemoGit.date(day: 15))
        try await b.git(["checkout", "-q", "main"])

        // 大小写修复分支(不合并,与指标分支改同一函数)
        try await b.git(["checkout", "-q", "-b", "fix/router-case", "main"])
        try b.write("Sources/AtlasCore/Router.swift", F.routerCaseFix)
        try await b.commit("fix: 路由路径大小写不敏感", by: .lin, at: DemoGit.date(day: 15, hour: 2))
        try await b.git(["checkout", "-q", "main"])

        try b.write("oma-demo.txt", F.omaDemo); try b.write("assets/logo.svg", F.logoSvg)
        try b.write("assets/logo.png", data: DemoImage.logoPNG()); try b.write("notebooks/analysis.ipynb", F.notebook)
        try await b.commit("chore: 增加演示文件与图片资源", by: .wen, at: DemoGit.date(day: 16))

        try b.write("web/src/components/Header.tsx", F.headerV2)
        try await b.commit("style: 页头组件补充类型定义", by: .chen, at: DemoGit.date(day: 17))

        // UI 分支(不合并,领先 2 个提交)
        try await b.git(["checkout", "-q", "-b", "feature/ui-polish", "main"])
        try b.write("web/src/theme.ts", F.themeTs)
        try await b.commit("feat: 深色模式主题变量", by: .chen, at: DemoGit.date(day: 18))
        try b.write("web/src/components/Header.tsx", F.headerV3)
        try await b.commit("style: 调整页头内边距", by: .wen, at: DemoGit.date(day: 18, hour: 4))
        try await b.git(["checkout", "-q", "main"])

        try await b.merge("feature/metrics", message: "Merge branch 'feature/metrics'", by: .wen, at: DemoGit.date(day: 19))

        try b.write("Sources/AtlasCore/Session.swift", F.sessionV3)
        try await b.commit("feat: 会话超时", by: .lin, at: DemoGit.date(day: 20))

        try b.write("README.md", F.readmeV2)
        try await b.commit("docs: 完善 README 与快速开始", by: .wen, at: DemoGit.date(day: 21))
        try await b.tag("v0.3.0", message: "指标与会话超时", by: .wen, at: DemoGit.date(day: 21, hour: 1))

        // 本地「远端」:推送后再提交一次,得到「领先 1」
        let remote = paths.remotes.appendingPathComponent("atlas-web.git")
        try await DemoGit.run(["clone", "-q", "--bare", b.directory.path, remote.path], in: paths.projects, home: paths.home)
        try await b.git(["remote", "add", "origin", remote.path])
        try await b.git(["fetch", "-q", "origin"])
        try await b.git(["branch", "-q", "--set-upstream-to=origin/main", "main"])

        try b.write("web/src/app.ts", F.appTs.replacingOccurrences(of: "bootstrap();\n", with: "bootstrap().catch(console.error);\n"))
        try await b.commit("fix: 启动失败时输出错误(尚未推送)", by: .lin, at: DemoGit.date(day: 22))

        // 两个 stash
        try b.write("Sources/AtlasCore/Cache.swift", F.cacheV2 + "\n// WIP: LRU 淘汰策略\nextension Cache {\n    func evictOldest() {}\n}\n")
        try await b.git(["stash", "push", "-q", "-m", "WIP: 缓存淘汰策略"], environment: DemoRepoBuilder.identity(.lin, DemoGit.date(day: 22, hour: 2)))
        try b.write("web/src/api.ts", F.apiV2 + "\n// 实验:失败自动重试\nexport async function withRetry<T>(run: () => Promise<T>, times = 3): Promise<T> {\n  for (let i = 0; ; i++) {\n    try { return await run(); } catch (error) { if (i >= times) throw error; }\n  }\n}\n")
        try await b.git(["stash", "push", "-q", "-m", "实验:请求重试"], environment: DemoRepoBuilder.identity(.chen, DemoGit.date(day: 22, hour: 3)))

        try await makeWorkingTreeChanges(b)
    }

    /// 工作区改动:已暂存、未暂存、同文件两种状态、新增、删除、重命名、未跟踪、大 Diff。
    static func makeWorkingTreeChanges(_ b: DemoRepoBuilder) async throws {
        typealias F = AtlasFiles
        // 已暂存的修改
        try b.write("Sources/AtlasCore/Session.swift", F.sessionV3.replacingOccurrences(of: "var timeout: TimeInterval = 1800", with: "var timeout: TimeInterval = 3600"))
        try await b.git(["add", "Sources/AtlasCore/Session.swift"])
        // 同一文件:先暂存一次修改,再做一次未暂存修改
        try b.write("README.md", F.readmeV2 + "\n## 许可\n\nMIT\n")
        try await b.git(["add", "README.md"])
        try b.write("README.md", F.readmeV2 + "\n## 许可\n\nMIT\n\n## 贡献\n\n欢迎提交 PR。\n")
        // 未暂存的修改
        try b.write("Sources/AtlasCore/Router.swift", F.routerMetrics.replacingOccurrences(of: "return handler(request)", with: "metrics.count(\"router.hit\")\n        return handler(request)"))
        // 已暂存的新文件
        try b.write("web/src/theme-dark.ts", "export const darkBackground = \"#1c1c1e\";\n")
        try await b.git(["add", "web/src/theme-dark.ts"])
        // 已暂存的重命名
        try FileManager.default.createDirectory(at: b.directory.appendingPathComponent("Sources/AtlasCore/Support"), withIntermediateDirectories: true)
        try await b.git(["mv", "Sources/AtlasCore/Util.swift", "Sources/AtlasCore/Support/Util.swift"])
        // 未暂存的删除
        try b.remove("Sources/AtlasCore/Legacy.swift")
        // 未跟踪
        try b.write("notes/todo.md", "# 待办\n\n- [ ] 补充指标文档\n- [ ] 评估 LRU 策略\n")
        try b.write("web/src/scratch.ts", "// 临时草稿\nexport const scratch = 1;\n")
        // 大 Diff:大段追加架构文档
        let extra = (1...40).map { "- 补充说明第 \($0) 条:请求在第 \($0) 个环节会被记录并上报。" }.joined(separator: "\n")
        try b.write("docs/architecture.md", F.architectureV2 + "\n## 观测性\n\n" + extra + "\n")
    }

    // MARK: 其他项目

    /// 干净的小仓库。
    static func buildNotes(paths: DemoPaths) async throws {
        let b = DemoRepoBuilder(directory: paths.project("notes-cli"), home: paths.home)
        try await b.initialize()
        try b.write("Package.swift", SmallFiles.notesPackage); try b.write("Sources/notes/main.swift", SmallFiles.notesMainV1)
        try b.write("README.md", SmallFiles.notesReadme)
        try await b.commit("chore: 初始化 notes", by: .wen, at: DemoGit.date(day: 0))
        try b.write("Sources/notes/main.swift", SmallFiles.notesMainV2)
        try await b.commit("feat: 命令行用法提示", by: .wen, at: DemoGit.date(day: 1))
        try await b.git(["checkout", "-q", "-b", "dev"])
        try b.write("Sources/notes/main.swift", SmallFiles.notesMainV3)
        try await b.commit("feat: add 与 list 子命令", by: .chen, at: DemoGit.date(day: 2))
        try await b.git(["checkout", "-q", "main"])
        try await b.merge("dev", message: "Merge branch 'dev'", by: .wen, at: DemoGit.date(day: 3))
        try await b.tag("v1.0.0", message: "首个正式版", by: .wen, at: DemoGit.date(day: 3, hour: 1))
        try b.write("README.md", SmallFiles.notesReadme + "\n用法见 `notes --help`。\n")
        try await b.commit("docs: 补充用法说明", by: .wen, at: DemoGit.date(day: 4))
    }

    /// 合并冲突中的仓库。
    static func buildMergeLab(paths: DemoPaths) async throws {
        let b = DemoRepoBuilder(directory: paths.project("merge-lab"), home: paths.home)
        try await b.initialize()
        try b.write("config.yaml", SmallFiles.mergeConfigBase); try b.write("calc.py", SmallFiles.mergeCalcBase)
        try await b.commit("chore: 初始配置与计算模块", by: .wen, at: DemoGit.date(day: 0))
        try await b.git(["checkout", "-q", "-b", "topic"])
        try b.write("config.yaml", SmallFiles.mergeConfigTopic); try b.write("calc.py", SmallFiles.mergeCalcTopic)
        try await b.commit("feat: 重试与超时调整,add 强制转 int", by: .chen, at: DemoGit.date(day: 1))
        try await b.git(["checkout", "-q", "main"])
        try b.write("config.yaml", SmallFiles.mergeConfigMain); try b.write("calc.py", SmallFiles.mergeCalcMain)
        try await b.commit("feat: 提高重试次数,add 补充文档", by: .lin, at: DemoGit.date(day: 2))
        // 制造冲突:合并失败是预期结果,保留合并中的状态
        try await b.git(["merge", "topic"], environment: DemoRepoBuilder.identity(.wen, DemoGit.date(day: 3)), allowFailure: true)
        try b.write("scratch.txt", "合并过程中的临时记录\n")
    }

    /// 非 Git 目录。
    static func buildLegacy(paths: DemoPaths) throws {
        let directory = paths.project("legacy-api")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try SmallFiles.legacyReadme.write(to: directory.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try SmallFiles.legacyServer.write(to: directory.appendingPathComponent("server.js"), atomically: true, encoding: .utf8)
        try SmallFiles.legacyPackage.write(to: directory.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
    }
}

/// 演示图片。
enum DemoImage {
    /// 生成 256×256 的渐变圆角方块 PNG(用于图片预览)。
    static func logoPNG() -> Data {
        let size = 256
        guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                        colors: [CGColor(red: 0.37, green: 0.36, blue: 0.9, alpha: 1), CGColor(red: 0.04, green: 0.52, blue: 1, alpha: 1)] as CFArray,
                                        locations: [0, 1]) else { return Data() }
        context.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: size, height: size), cornerWidth: 56, cornerHeight: 56, transform: nil))
        context.clip()
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size), end: CGPoint(x: size, y: 0), options: [])
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.move(to: CGPoint(x: 64, y: 72)); context.addLine(to: CGPoint(x: 128, y: 200))
        context.addLine(to: CGPoint(x: 192, y: 72)); context.addLine(to: CGPoint(x: 164, y: 72))
        context.addLine(to: CGPoint(x: 128, y: 148)); context.addLine(to: CGPoint(x: 92, y: 72)); context.closePath()
        context.fillPath()
        guard let image = context.makeImage() else { return Data() }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return Data() }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }
}
