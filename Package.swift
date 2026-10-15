// swift-tools-version: 6.4
// @author ygw
// OhMyAgent:macOS 27 原生 Claude Code Agent 客户端
import PackageDescription

let package = Package(
    name: "OhMyAgent",
    platforms: [.macOS(.v27)],
    products: [
        .executable(name: "OhMyAgent", targets: ["OhMyAgentApp"]),
        .executable(name: "FakeAgent", targets: ["FakeAgent"]),
        .executable(name: "OhMyAgentBridge", targets: ["OhMyAgentBridge"]),
    ],
    dependencies: [
        // 终端模拟器(VT/xterm 解析与渲染视图)
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.5.1"),
    ],
    targets: [
        // 统一日志:os.Logger + 文件轮转 + 脱敏 + 协议流量日志
        .target(name: "OMLog"),
        // 协议层:JSON-RPC、ACP v1 模型、连接 actor
        .target(name: "ACPKit", dependencies: ["OMLog"]),
        // 宿主层:子进程、Agent 注册表、路径探测、Bridge
        .target(name: "AgentHost", dependencies: ["ACPKit", "OMLog"]),
        // 配置层:读写 ~/.claude 与 .mcp.json 等
        .target(name: "ClaudeConfigKit", dependencies: ["OMLog"]),
        // Diff 与检查点
        .target(name: "DiffKit"),
        // AppKit TextKit 2 编辑器
        .target(name: "EditorKit", dependencies: ["DiffKit"]),
        // Lucide 原生图标:SVG path 解析 + 模板图像渲染
        .target(name: "IconKit", dependencies: ["OMLog"]),
        // Mermaid 原生渲染:解析 → 分层布局 → 绘制场景(纯 Swift,无 WebView)
        .target(name: "MermaidKit"),
        // Git:git 命令的类型化封装与输出解析(后台子进程,无 UI)
        .target(name: "GitKit", dependencies: ["DiffKit", "OMLog"]),
        // LSP 客户端:Content-Length 分帧、客户端 actor、服务器定位与管理(复用 ACPKit 的 JSON-RPC 连接,无 UI)
        .target(name: "LSPKit", dependencies: ["ACPKit", "OMLog"]),
        // Liquid Glass 设计系统
        .target(name: "DesignSystem", dependencies: ["IconKit"]),
        // 聊天核心:时间线模型、事件合并、Markdown 解析、会话模型(不含视图)
        .target(name: "ChatKit", dependencies: ["ACPKit", "AgentHost", "DiffKit", "OMLog"]),
        // 工作台:项目/会话树、布局、持久化(不含视图)
        .target(name: "WorkbenchKit", dependencies: ["ACPKit", "AgentHost", "ChatKit", "OMLog"]),
        // 应用本体
        .executableTarget(
            name: "OhMyAgentApp",
            dependencies: ["ACPKit", "AgentHost", "ChatKit", "ClaudeConfigKit", "DiffKit", "EditorKit", "DesignSystem", "IconKit", "MermaidKit", "GitKit", "LSPKit", "OMLog", "WorkbenchKit",
                           .product(name: "SwiftTerm", package: "SwiftTerm")]
        ),
        // 脚本化 ACP Agent,用于测试与预览
        .executableTarget(name: "FakeAgent", dependencies: ["ACPKit"]),
        // Bridge 的 stdio ↔ Unix socket 垫片
        .executableTarget(name: "OhMyAgentBridge", dependencies: ["OMLog"]),
        // M0 spike
        .executableTarget(name: "ACPSpike", dependencies: ["ACPKit", "AgentHost"]),
        .executableTarget(name: "EditorSpike", dependencies: ["EditorKit"]),
        // 测试
        .testTarget(name: "OMLogTests", dependencies: ["OMLog"]),
        .testTarget(name: "ACPKitTests", dependencies: ["ACPKit"]),
        .testTarget(name: "AgentHostTests", dependencies: ["AgentHost", "ACPKit", "FakeAgent"]),
        .testTarget(name: "ChatKitTests", dependencies: ["ChatKit", "ACPKit", "AgentHost", "FakeAgent"]),
        .testTarget(name: "ClaudeConfigKitTests", dependencies: ["ClaudeConfigKit"]),
        .testTarget(name: "DiffKitTests", dependencies: ["DiffKit"]),
        .testTarget(name: "GitKitTests", dependencies: ["GitKit", "DiffKit"]),
        .testTarget(name: "IconKitTests", dependencies: ["IconKit"]),
        .testTarget(name: "LSPKitTests", dependencies: ["LSPKit", "ACPKit"]),
        .testTarget(name: "MermaidKitTests", dependencies: ["MermaidKit"]),
        .testTarget(name: "OhMyAgentAppTests", dependencies: ["OhMyAgentApp", "ChatKit", "ACPKit", "DesignSystem"]),
        .testTarget(name: "WorkbenchKitTests", dependencies: ["WorkbenchKit", "ChatKit", "ACPKit", "AgentHost", "FakeAgent"]),
    ]
)
