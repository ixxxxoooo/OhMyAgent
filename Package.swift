// swift-tools-version: 6.4
// @author ixxxxoooo
// OhMyAgent:macOS 27 原生 Claude Code Agent 客户端
import PackageDescription

let package = Package(
    name: "OhMyAgent",
    platforms: [.macOS(.v27)],
    products: [
        .executable(name: "OhMyAgent", targets: ["OhMyAgentApp"]),
        .executable(name: "FakeAgent", targets: ["FakeAgent"]),
    ],
    dependencies: [
        // 终端模拟器(VT/xterm 解析与渲染视图)
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.11.2"),
    ],
    targets: [
        // tree-sitter 运行时(C,v0.25.10,MIT):增量解析与查询,供编辑器语法高亮使用
        .target(
            name: "CTreeSitter",
            path: "Vendor/TreeSitter",
            exclude: ["LICENSE"],
            sources: ["src/lib.c"],
            publicHeadersPath: "include",
            cSettings: [.headerSearchPath("src"), .headerSearchPath("src/wasm"), .unsafeFlags(["-w", "-O2"])]
        ),
        // 各语言 tree-sitter 语法(生成的 C 解析器,体量大,各自随上游许可证)
        .target(
            name: "TreeSitterGrammars",
            dependencies: ["CTreeSitter"],
            path: "Vendor/TreeSitterGrammars",
            exclude: ["LICENSE.swift", "LICENSE.javascript", "LICENSE.python", "LICENSE.rust"],
            publicHeadersPath: "include",
            cSettings: [.headerSearchPath("typescript/src"), .unsafeFlags(["-w", "-O2"])]
        ),
        // 统一日志:os.Logger + 文件轮转 + 脱敏 + 协议流量日志
        .target(name: "OMLog"),
        // 协议层:JSON-RPC、ACP v1 模型、连接 actor
        .target(name: "ACPKit", dependencies: ["OMLog"]),
        // Claude Code 原生 ACP 适配器:Swift 实现的进程内 Agent,经 stream-json 控制协议驱动本机 `claude`(替代 Node 版 claude-agent-acp)
        .target(name: "ClaudeAgentKit", dependencies: ["ACPKit", "OMLog"]),
        // 宿主层:子进程、Agent 注册表、路径探测、Bridge
        .target(name: "AgentHost", dependencies: ["ACPKit", "ClaudeAgentKit", "OMLog", "ProviderProxyKit"]),
        // 配置层:读写 ~/.claude 与 .mcp.json 等
        .target(name: "ClaudeConfigKit", dependencies: ["OMLog"]),
        // Diff 与检查点
        .target(name: "DiffKit"),
        // 编辑器内核(无视图):持久化文本绳、撤销栈、共享文档;视图模型与装饰随 E2 起加入
        .target(name: "EditorCore"),
        // AppKit TextKit 2 编辑器
        .target(name: "EditorKit", dependencies: ["DiffKit", "DesignSystem", "IconKit", "OMLog", "CTreeSitter", "TreeSitterGrammars"]),
        // Lucide 原生图标:SVG path 解析 + 模板图像渲染
        .target(name: "IconKit", dependencies: ["OMLog"]),
        // Mermaid 原生渲染:解析 → 分层布局 → 绘制场景(纯 Swift,无 WebView)
        .target(name: "MermaidKit"),
        // 表格:xlsx(ZIP + OOXML)原生读取,流式解析为行列矩阵(无视图)
        .target(name: "SpreadsheetKit"),
        // Canvas:声明式画布文档(块列表)的模型、校验与落盘存储(无视图)
        .target(name: "CanvasKit", dependencies: ["OMLog"]),
        .target(name: "AutomationKit", dependencies: ["OMLog"]),
        // Git:git 命令的类型化封装与输出解析(后台子进程,无 UI)
        .target(name: "GitKit", dependencies: ["DiffKit", "OMLog"]),
        // LSP 客户端:Content-Length 分帧、客户端 actor、服务器定位与管理(复用 ACPKit 的 JSON-RPC 连接,无 UI)
        .target(name: "LSPKit", dependencies: ["ACPKit", "OMLog"]),
        // IDE 模式数据层:每窗口模型、窗口注册表、命令注册表、问题聚合(无视图)
        .target(name: "IDEKit", dependencies: ["OMLog", "WorkbenchKit"]),
        // 演示模式数据:确定性生成演示项目、Git 仓库、历史会话与演示用 Claude 配置(无视图)
        .target(name: "DemoKit", dependencies: ["ACPKit", "CanvasKit", "OMLog", "WorkbenchKit"]),
        // Liquid Glass 设计系统
        .target(name: "DesignSystem", dependencies: ["IconKit", "OMLog"]),
        // 模型协议代理:本地回环 HTTP,把 Anthropic /v1/messages 转换为 OpenAI /chat/completions(无视图)
        .target(name: "ProviderProxyKit", dependencies: ["OMLog"]),
        // 聊天核心:时间线模型、事件合并、Markdown 解析、会话模型(不含视图)
        .target(name: "ChatKit", dependencies: ["ACPKit", "AgentHost", "CanvasKit", "DiffKit", "OMLog", "ProviderProxyKit"]),
        // 工作台:项目/会话树、布局、持久化(不含视图)
        .target(name: "WorkbenchKit", dependencies: ["ACPKit", "AgentHost", "ChatKit", "GitKit", "OMLog"]),
        // 应用本体
        .executableTarget(
            name: "OhMyAgentApp",
            dependencies: ["ACPKit", "AgentHost", "ChatKit", "ClaudeConfigKit", "DiffKit", "EditorKit", "DesignSystem", "IconKit", "MermaidKit", "GitKit", "LSPKit", "DemoKit", "OMLog", "SpreadsheetKit", "AutomationKit", "WorkbenchKit", "CanvasKit", "IDEKit",
                           .product(name: "SwiftTerm", package: "SwiftTerm")]
        ),
        // 脚本化 ACP Agent,用于测试与预览
        .executableTarget(name: "FakeAgent", dependencies: ["ACPKit"]),
        // M0 spike
        .executableTarget(name: "ACPSpike", dependencies: ["ACPKit", "AgentHost"]),
        .executableTarget(name: "EditorSpike", dependencies: ["EditorKit", "DemoKit", "OMLog"]),
        // 原生 Claude 适配器的 stdio 宿主(差分对照与联调用,不随应用分发)
        .executableTarget(name: "ClaudeACPHost", dependencies: ["ACPKit", "ClaudeAgentKit"]),
        // 测试
        .testTarget(name: "ProviderProxyKitTests", dependencies: ["ProviderProxyKit"]),
        .testTarget(name: "OMLogTests", dependencies: ["OMLog"]),
        .testTarget(name: "ACPKitTests", dependencies: ["ACPKit"]),
        .testTarget(name: "AgentHostTests", dependencies: ["AgentHost", "ACPKit", "FakeAgent"]),
        .testTarget(name: "ChatKitTests", dependencies: ["ChatKit", "ACPKit", "AgentHost", "FakeAgent"]),
        .testTarget(name: "ClaudeConfigKitTests", dependencies: ["ClaudeConfigKit"]),
        .testTarget(name: "ClaudeAgentKitTests", dependencies: ["ClaudeAgentKit", "ACPKit"]),
        .testTarget(name: "DemoKitTests", dependencies: ["DemoKit", "GitKit", "ClaudeConfigKit", "WorkbenchKit", "ACPKit"]),
        .testTarget(name: "DiffKitTests", dependencies: ["DiffKit"]),
        .testTarget(name: "GitKitTests", dependencies: ["GitKit", "DiffKit"]),
        .testTarget(name: "IconKitTests", dependencies: ["IconKit"]),
        .testTarget(name: "LSPKitTests", dependencies: ["LSPKit", "ACPKit"]),
        .testTarget(name: "SpreadsheetKitTests", dependencies: ["SpreadsheetKit"]),
        .testTarget(name: "CanvasKitTests", dependencies: ["CanvasKit"]),
        .testTarget(name: "AutomationKitTests", dependencies: ["AutomationKit"]),
        .testTarget(name: "EditorKitTests", dependencies: ["EditorKit"]),
        .testTarget(name: "EditorCoreTests", dependencies: ["EditorCore"]),
        .testTarget(name: "IDEKitTests", dependencies: ["IDEKit", "WorkbenchKit"]),
        .testTarget(name: "MermaidKitTests", dependencies: ["MermaidKit"]),
        .testTarget(name: "OhMyAgentAppTests", dependencies: ["OhMyAgentApp", "ChatKit", "ACPKit", "DesignSystem", "EditorKit", "LSPKit", "CanvasKit", "DemoKit"]),
        .testTarget(name: "WorkbenchKitTests", dependencies: ["WorkbenchKit", "ChatKit", "ACPKit", "AgentHost", "FakeAgent"]),
    ]
)
