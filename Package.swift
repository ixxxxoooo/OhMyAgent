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
    ],
    targets: [
        // 协议层:JSON-RPC、ACP v1 模型、连接 actor
        .target(name: "ACPKit"),
        // 宿主层:子进程、Agent 注册表、路径探测、Bridge、直连兜底
        .target(name: "AgentHost", dependencies: ["ACPKit"]),
        // 配置层:读写 ~/.claude 与 .mcp.json 等
        .target(name: "ClaudeConfigKit"),
        // Diff 与检查点
        .target(name: "DiffKit"),
        // AppKit TextKit 2 编辑器
        .target(name: "EditorKit", dependencies: ["DiffKit"]),
        // Liquid Glass 设计系统
        .target(name: "DesignSystem"),
        // 聊天核心:时间线模型、事件合并、Markdown 解析、会话模型(不含视图)
        .target(name: "ChatKit", dependencies: ["ACPKit", "AgentHost", "DiffKit"]),
        // 应用本体
        .executableTarget(
            name: "OhMyAgentApp",
            dependencies: ["ACPKit", "AgentHost", "ChatKit", "ClaudeConfigKit", "DiffKit", "EditorKit", "DesignSystem"]
        ),
        // 脚本化 ACP Agent,用于测试与预览
        .executableTarget(name: "FakeAgent", dependencies: ["ACPKit"]),
        // M0 spike
        .executableTarget(name: "ACPSpike", dependencies: ["ACPKit", "AgentHost"]),
        .executableTarget(name: "EditorSpike", dependencies: ["EditorKit"]),
        // 测试
        .testTarget(name: "ACPKitTests", dependencies: ["ACPKit"]),
        .testTarget(name: "AgentHostTests", dependencies: ["AgentHost", "ACPKit", "FakeAgent"]),
        .testTarget(name: "ChatKitTests", dependencies: ["ChatKit", "ACPKit", "AgentHost", "FakeAgent"]),
        .testTarget(name: "ClaudeConfigKitTests", dependencies: ["ClaudeConfigKit"]),
        .testTarget(name: "DiffKitTests", dependencies: ["DiffKit"]),
    ]
)
