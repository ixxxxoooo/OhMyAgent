// @author ygw
// AgentHost 单元与集成测试。

import ACPKit
import Foundation
import Testing
@testable import AgentHost

@Suite("工具定位")
struct LocatorTests {
    @Test("版本号解析与比较")
    func versions() {
        #expect(ExecutableLocator.majorVersion("v22.18.0") == 22)
        #expect(ExecutableLocator.majorVersion("26.8.1") == 26)
        #expect(ExecutableLocator.compareVersions("v22.19.0", "v22.18.0") == 1)
        #expect(ExecutableLocator.compareVersions("v22.0.0", "v26.8.1") == -1)
        #expect(ExecutableLocator.compareVersions("v22.0.0", "v22.0.0") == 0)
    }

    @Test("解析带标记的 env -0 输出并剥离 shell 噪声")
    func envParsing() {
        var data = Data("noise\n__OMA_ENV_START__".utf8)
        data.append(contentsOf: Array("PATH=/a:/b".utf8) + [0] + Array("FOO=bar=baz".utf8) + [0])
        data.append(Data("__OMA_ENV_END__trailing".utf8))
        let env = ShellEnvironment.parse(data)
        #expect(env?["PATH"] == "/a:/b")
        #expect(env?["FOO"] == "bar=baz")
        #expect(ShellEnvironment.parse(Data("garbage".utf8)) == nil)
    }

    @Test("Claude 提供者缺少依赖时给出明确错误")
    func missingTools() {
        let provider = ClaudeACPProvider()
        let tools = LocatedTools(nodePath: nil, nodeVersion: nil, claudePath: nil, adapterEntry: nil, environment: [:])
        #expect(throws: AgentLaunchError.self) { try provider.makeLaunch(cwd: "/tmp", tools: tools) }
    }

    @Test("Claude 提供者设置 CLAUDE_CODE_EXECUTABLE")
    func claudeEnv() throws {
        let tools = LocatedTools(nodePath: "/n", nodeVersion: "v22", claudePath: "/c", adapterEntry: "/a.js", environment: ["PATH": "/bin"])
        let launch = try ClaudeACPProvider().makeLaunch(cwd: "/work", tools: tools)
        #expect(launch.executable == "/n")
        #expect(launch.arguments == ["/a.js"])
        #expect(launch.environment["CLAUDE_CODE_EXECUTABLE"] == "/c")
        #expect(launch.workingDirectory == "/work")
    }

    @Test("通用 ACP 提供者在 PATH 中解析命令")
    func genericResolve() throws {
        let descriptor = AgentDescriptor(id: "x", name: "X", kind: .genericACP, command: "sh", args: ["-c", "true"])
        let tools = LocatedTools(nodePath: nil, nodeVersion: nil, claudePath: nil, adapterEntry: nil, environment: ["PATH": "/bin:/usr/bin"])
        let launch = try GenericACPProvider(descriptor: descriptor).makeLaunch(cwd: "/tmp", tools: tools)
        #expect(launch.executable.hasSuffix("/sh"))
    }
}

/// 工程根目录(测试从包根目录运行)。
private let packageRoot: String = {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<3 { url.deleteLastPathComponent() }
    return url.path
}()

@Suite("子进程集成", .serialized)
struct ProcessIntegrationTests {
    @Test("通过真实子进程运行 FakeAgent 完成一轮对话")
    func fakeAgentOverStdio() async throws {
        // FakeAgent 与测试产物在同一目录
        let candidates = Bundle.allBundles.map { ($0.bundlePath as NSString).deletingLastPathComponent } + ["\(packageRoot)/.build/out/Products/Debug", "\(packageRoot)/.build/debug", "\(packageRoot)/.build/arm64-apple-macosx/debug"]
        let dir = try #require(candidates.first { FileManager.default.isExecutableFile(atPath: "\($0)/FakeAgent") }, "未找到 FakeAgent,候选目录: \(candidates)")
        let exe = "\(dir)/FakeAgent"
        let descriptor = AgentDescriptor(id: "fake", name: "Fake", kind: .genericACP, command: exe)
        let supervisor = AgentSupervisor(provider: GenericACPProvider(descriptor: descriptor), cwd: "/tmp", delegate: AutoAllowDelegate())
        let tools = LocatedTools(nodePath: nil, nodeVersion: nil, claudePath: nil, adapterEntry: nil, environment: ProcessInfo.processInfo.environment)
        let result = try await supervisor.start(tools: tools)
        #expect(result.agentName == "scripted-agent")
        let client = try #require(await supervisor.client)
        let setup = try await client.newSession(cwd: "/tmp")
        let stop = try await client.prompt(sessionId: setup.sessionId, content: [.text("hi")])
        #expect(stop == .endTurn)
        await supervisor.stop()
    }

    @Test("真实 claude-agent-acp 完成握手(环境具备时)")
    func realAdapterHandshake() async throws {
        let env = ProcessInfo.processInfo.environment
        let tools = ExecutableLocator.locate(projectRoot: packageRoot, environment: env)
        guard tools.isACPReady, tools.claudePath != nil else { return }
        let supervisor = AgentSupervisor(provider: ClaudeACPProvider(), cwd: packageRoot, delegate: AutoAllowDelegate())
        let result = try await supervisor.start(tools: tools)
        #expect(result.protocolVersion == 1)
        #expect(result.capabilities.canList)
        #expect(result.agentName.contains("claude"))
        await supervisor.stop()
    }
}

struct AutoAllowDelegate: ACPClientDelegate {
    func requestPermission(_ request: PermissionRequest) async -> PermissionOutcome {
        .selected(optionId: request.options.first { $0.kind == .allowOnce }?.optionId ?? "allow")
    }
}
