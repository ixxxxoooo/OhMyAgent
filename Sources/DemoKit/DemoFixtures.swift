// @author ygw
// 演示项目的文件内容。内容刻意写得像真实项目(Swift + TypeScript + Markdown),
// 以便代码高亮、Diff、blame、Markdown/Mermaid 预览都有真东西可看。

import Foundation

/// `atlas-web` 演示项目的文件内容(同一文件的多个版本用 v1/v2… 区分,模拟提交历史里的演进)。
enum AtlasFiles {
    static let gitignore = ".build/\nnode_modules/\ndist/\n.DS_Store\n"

    static let packageSwift = """
    // swift-tools-version: 6.0
    import PackageDescription

    let package = Package(
        name: "AtlasCore",
        platforms: [.macOS(.v14)],
        products: [.library(name: "AtlasCore", targets: ["AtlasCore"])],
        targets: [
            .target(name: "AtlasCore"),
            .testTarget(name: "AtlasCoreTests", dependencies: ["AtlasCore"]),
        ]
    )

    """

    static let readmeV1 = "# Atlas\n\nAtlas 是一个轻量的 Web 服务内核。\n\n## 目录\n\n- `Sources/AtlasCore`:路由、会话、缓存\n- `web`:前端\n- `docs`:设计文档\n"

    static let readmeV2 = "# Atlas\n\nAtlas 是一个轻量的 Web 服务内核,包含路由、会话与缓存三个核心模块。\n\n## 快速开始\n\n```bash\nswift build\nswift test\ncd web && npm ci && npm run dev\n```\n\n## 目录\n\n- `Sources/AtlasCore`:路由、会话、缓存、指标\n- `web`:前端(Vite + TypeScript)\n- `docs`:设计文档\n"

    static let models = """
    import Foundation

    /// 一次请求。
    struct Request: Sendable {
        var method: String
        var path: String
        var body: Data?

        static func get(_ path: String) -> Request { Request(method: "GET", path: path, body: nil) }
    }

    /// 一次响应。
    enum Response: Sendable, Equatable {
        case ok
        case json(String)
        case notFound
        case failure(code: Int)
    }

    """

    static let routerV1 = """
    import Foundation

    /// 请求路由:把路径映射到处理函数。
    final class Router {
        private var handlers: [(path: String, handler: (Request) -> Response)] = []

        func register(_ path: String, _ handler: @escaping (Request) -> Response) {
            handlers.append((path, handler))
        }
    }

    """

    static let routerV2 = """
    import Foundation

    /// 请求路由:把路径映射到处理函数。
    final class Router {
        private var handlers: [(path: String, handler: (Request) -> Response)] = []

        func register(_ path: String, _ handler: @escaping (Request) -> Response) {
            handlers.append((path, handler))
        }

        func route(_ request: Request) -> Response {
            for entry in handlers where entry.path == request.path {
                return entry.handler(request)
            }
            return .notFound
        }
    }

    """

    static let routerV3 = """
    import Foundation

    /// 请求路由:把路径映射到处理函数。
    final class Router {
        private var handlers: [String: (Request) -> Response] = [:]

        func register(_ path: String, _ handler: @escaping (Request) -> Response) {
            handlers[path] = handler
        }

        func route(_ request: Request) -> Response {
            return handlers[request.path]?(request) ?? .notFound
        }
    }

    """

    /// 指标分支:未命中时计数。
    static let routerMetrics = """
    import Foundation

    /// 请求路由:把路径映射到处理函数。
    final class Router {
        private var handlers: [String: (Request) -> Response] = [:]
        private let metrics: Metrics

        init(metrics: Metrics = Metrics()) {
            self.metrics = metrics
        }

        func register(_ path: String, _ handler: @escaping (Request) -> Response) {
            handlers[path] = handler
        }

        func route(_ request: Request) -> Response {
            guard let handler = handlers[request.path] else {
                metrics.count("router.miss")
                return .notFound
            }
            return handler(request)
        }
    }

    """

    /// 修复分支:路径大小写不敏感(与指标分支修改同一函数,合并会冲突)。
    static let routerCaseFix = """
    import Foundation

    /// 请求路由:把路径映射到处理函数。
    final class Router {
        private var handlers: [String: (Request) -> Response] = [:]

        func register(_ path: String, _ handler: @escaping (Request) -> Response) {
            handlers[path.lowercased()] = handler
        }

        func route(_ request: Request) -> Response {
            return handlers[request.path.lowercased()]?(request) ?? .notFound
        }
    }

    """

    static let sessionV1 = """
    import Foundation

    /// 一个客户端会话。
    final class Session {
        let id = UUID()
        let router = Router()

        func handle(_ request: Request) -> Response {
            let response = router.route(request)
            return response
        }
    }

    """

    static let sessionV2 = """
    import Foundation

    /// 一个客户端会话(支持持久化)。
    final class Session: Codable {
        let id: UUID
        var createdAt: Date
        let router = Router()

        init(id: UUID = UUID(), createdAt: Date = Date()) {
            self.id = id
            self.createdAt = createdAt
        }

        func handle(_ request: Request) -> Response {
            let response = router.route(request)
            return response
        }

        enum CodingKeys: String, CodingKey { case id, createdAt }
    }

    """

    static let sessionV3 = """
    import Foundation

    /// 一个客户端会话(支持持久化与超时)。
    final class Session: Codable {
        let id: UUID
        var createdAt: Date
        var timeout: TimeInterval = 1800
        let router = Router()

        init(id: UUID = UUID(), createdAt: Date = Date()) {
            self.id = id
            self.createdAt = createdAt
        }

        /// 会话是否已超时。
        func isExpired(now: Date = Date()) -> Bool {
            now.timeIntervalSince(createdAt) > timeout
        }

        func handle(_ request: Request) -> Response {
            let response = router.route(request)
            return response
        }

        enum CodingKeys: String, CodingKey { case id, createdAt, timeout }
    }

    """

    static let cacheV1 = """
    import Foundation

    /// 简单的内存缓存。
    final class Cache<Value> {
        private var storage: [String: (value: Value, expiresAt: Date)] = [:]

        func set(_ key: String, _ value: Value, ttl: TimeInterval) {
            storage[key] = (value, Date().addingTimeInterval(ttl))
        }

        func get(_ key: String) -> Value? {
            guard let entry = storage[key], entry.expiresAt > Date() else { return nil }
            return entry.value
        }
    }

    """

    static let cacheV2 = """
    import Foundation

    /// 简单的内存缓存(过期边界按「到点即失效」处理)。
    final class Cache<Value> {
        private var storage: [String: (value: Value, expiresAt: Date)] = [:]

        func set(_ key: String, _ value: Value, ttl: TimeInterval) {
            storage[key] = (value, Date().addingTimeInterval(ttl))
        }

        func get(_ key: String) -> Value? {
            guard let entry = storage[key], entry.expiresAt >= Date() else {
                storage[key] = nil
                return nil
            }
            return entry.value
        }

        var count: Int { storage.count }
    }

    """

    static let utilV1 = "import Foundation\n\nfunc clamp<T: Comparable>(_ value: T, _ range: ClosedRange<T>) -> T {\n    min(max(value, range.lowerBound), range.upperBound)\n}\n"

    static let utilV2 = "import Foundation\n\n/// 把数值限制在闭区间内。\nfunc clamp<T: Comparable>(_ value: T, _ range: ClosedRange<T>) -> T {\n    min(max(value, range.lowerBound), range.upperBound)\n}\n\n/// 人类可读的字节数。\nfunc formatBytes(_ count: Int) -> String {\n    ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)\n}\n"

    static let legacy = "import Foundation\n\n// 旧版兼容层,计划在 0.4 移除。\nenum Legacy {\n    static func oldRoute(_ path: String) -> String { \"/v1\" + path }\n}\n"

    static let metrics = """
    import Foundation

    /// 轻量计数器。
    final class Metrics: @unchecked Sendable {
        private var counters: [String: Int] = [:]
        private let lock = NSLock()

        func count(_ name: String) {
            lock.lock(); defer { lock.unlock() }
            counters[name, default: 0] += 1
        }

        func value(of name: String) -> Int {
            lock.lock(); defer { lock.unlock() }
            return counters[name, default: 0]
        }
    }

    """

    static let routerTests = """
    import Testing
    @testable import AtlasCore

    @Suite("Router")
    struct RouterTests {
        @Test("命中已注册路径")
        func hit() {
            let router = Router()
            router.register("/") { _ in .ok }
            #expect(router.route(.get("/")) == .ok)
        }

        @Test("未命中返回 notFound")
        func miss() {
            let router = Router()
            #expect(router.route(.get("/nope")) == .notFound)
        }
    }

    """

    static let metricsTests = """
    import Testing
    @testable import AtlasCore

    @Suite("Metrics")
    struct MetricsTests {
        @Test("计数累加")
        func counting() {
            let metrics = Metrics()
            metrics.count("a"); metrics.count("a")
            #expect(metrics.value(of: "a") == 2)
        }
    }

    """

    static let architectureV1 = "# 架构\n\n请求先进入 `Router`,再交给 `Session` 处理;`Cache` 为两者提供短期缓存。\n\n## 模块\n\n| 模块 | 职责 |\n| --- | --- |\n| Router | 路径分发 |\n| Session | 会话生命周期 |\n| Cache | 带 TTL 的内存缓存 |\n"

    static let architectureV2 = architectureV1 + """

    ## 请求流程

    ```mermaid
    sequenceDiagram
      participant C as 客户端
      participant S as Session
      participant R as Router
      C->>S: 发起请求
      S->>R: route(request)
      R-->>S: Response
      S-->>C: 返回响应
    ```

    ## 状态

    ```mermaid
    stateDiagram-v2
      [*] --> Active
      Active --> Expired : 超时
      Expired --> [*]
    ```

    """

    static let packageJson = "{\n  \"name\": \"atlas-web\",\n  \"private\": true,\n  \"version\": \"0.3.0\",\n  \"scripts\": { \"dev\": \"vite\", \"build\": \"vite build\", \"lint\": \"eslint src\" },\n  \"dependencies\": { \"react\": \"^18.3.0\" }\n}\n"

    static let appTs = "import { fetchUser } from \"./api\";\n\nexport async function bootstrap(): Promise<void> {\n  const user = await fetchUser(\"me\");\n  document.title = `Atlas · ${user.name}`;\n}\n\nbootstrap();\n"

    static let apiV1 = "export interface User {\n  id: string;\n  name: string;\n}\n\nexport async function fetchUser(id: string): Promise<User> {\n  const response = await fetch(`/api/users/${id}`);\n  return response.json();\n}\n"

    static let apiV2 = "export interface User {\n  id: string;\n  name: string;\n}\n\nexport class ApiError extends Error {\n  constructor(readonly code: number, message: string) {\n    super(message);\n  }\n}\n\nexport async function fetchUser(id: string): Promise<User> {\n  const response = await fetch(`/api/users/${id}`);\n  if (!response.ok) throw new ApiError(response.status, response.statusText);\n  return response.json();\n}\n"

    static let headerV1 = "import React from \"react\";\n\nexport function Header({ title }: { title: string }) {\n  return <header className=\"header\">{title}</header>;\n}\n"

    static let headerV2 = "import React from \"react\";\n\ninterface HeaderProps {\n  title: string;\n}\n\nexport function Header({ title }: HeaderProps) {\n  return <header className=\"header\">{title}</header>;\n}\n"

    static let headerV3 = "import React from \"react\";\n\ninterface HeaderProps {\n  title: string;\n}\n\nexport function Header({ title }: HeaderProps) {\n  return (\n    <header className=\"header\" style={{ padding: \"12px 20px\" }}>\n      {title}\n    </header>\n  );\n}\n"

    static let themeTs = "export const theme = {\n  light: { background: \"#ffffff\", text: \"#1d1d1f\" },\n  dark: { background: \"#1c1c1e\", text: \"#f5f5f7\" },\n};\n"

    static let omaDemo = (1...10).map { "line \($0)" }.joined(separator: "\n") + "\n"

    static let logoSvg = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"128\" height=\"128\" viewBox=\"0 0 128 128\">\n  <defs><linearGradient id=\"g\" x1=\"0\" y1=\"0\" x2=\"1\" y2=\"1\"><stop offset=\"0\" stop-color=\"#5e5ce6\"/><stop offset=\"1\" stop-color=\"#0a84ff\"/></linearGradient></defs>\n  <rect width=\"128\" height=\"128\" rx=\"28\" fill=\"url(#g)\"/>\n  <path d=\"M32 92 64 28l32 64h-14l-18-38-18 38z\" fill=\"#fff\"/>\n</svg>\n"

    static let notebook = "{\n \"cells\": [\n  {\"cell_type\": \"markdown\", \"id\": \"c1\", \"metadata\": {}, \"source\": [\"# 请求量分析\"]},\n  {\"cell_type\": \"code\", \"id\": \"c3\", \"metadata\": {}, \"execution_count\": null, \"outputs\": [], \"source\": [\"df.describe()\"]}\n ],\n \"metadata\": {\"kernelspec\": {\"display_name\": \"Python 3\", \"language\": \"python\", \"name\": \"python3\"}},\n \"nbformat\": 4,\n \"nbformat_minor\": 5\n}\n"
}

/// 其余演示项目的文件内容。
enum SmallFiles {
    static let notesPackage = "// swift-tools-version: 6.0\nimport PackageDescription\n\nlet package = Package(name: \"notes\", targets: [.executableTarget(name: \"notes\")])\n"
    static let notesMainV1 = "print(\"notes 0.1\")\n"
    static let notesMainV2 = "import Foundation\n\nlet arguments = CommandLine.arguments.dropFirst()\nif arguments.isEmpty {\n    print(\"用法: notes add <内容> | notes list\")\n}\n"
    static let notesMainV3 = "import Foundation\n\nlet arguments = CommandLine.arguments.dropFirst()\nswitch arguments.first {\ncase \"add\": print(\"已添加\")\ncase \"list\": print(\"(空)\")\ndefault: print(\"用法: notes add <内容> | notes list\")\n}\n"
    static let notesReadme = "# notes\n\n一个很小的命令行笔记工具。\n"

    static let mergeConfigBase = "name: lab\nretries: 3\ntimeout: 30\nmode: safe\n"
    static let mergeConfigMain = "name: lab\nretries: 5\ntimeout: 30\nmode: safe\n"
    static let mergeConfigTopic = "name: lab\nretries: 2\ntimeout: 60\nmode: safe\n"
    static let mergeCalcBase = "def add(a, b):\n    return a + b\n\n\ndef sub(a, b):\n    return a - b\n"
    static let mergeCalcMain = "def add(a, b):\n    \"\"\"加法。\"\"\"\n    return a + b\n\n\ndef sub(a, b):\n    return a - b\n"
    static let mergeCalcTopic = "def add(a, b):\n    return int(a) + int(b)\n\n\ndef sub(a, b):\n    return a - b\n"

    static let legacyReadme = "# legacy-api\n\n旧版接口服务,尚未纳入版本管理。\n"
    static let legacyServer = "const http = require(\"http\");\n\nhttp.createServer((req, res) => {\n  res.end(\"legacy ok\");\n}).listen(3000);\n"
    static let legacyPackage = "{\n  \"name\": \"legacy-api\",\n  \"version\": \"0.0.1\",\n  \"main\": \"server.js\"\n}\n"
}
