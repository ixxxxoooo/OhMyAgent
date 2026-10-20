// @author ixxxxoooo
// AgentHost 单元与集成测试。

import ACPKit
import Foundation
import Testing
@testable import AgentHost

@Suite("工具定位")
struct LocatorTests {
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

    @Test("Claude 提供者缺少 claude 时给出明确错误")
    func missingTools() {
        let provider = ClaudeACPProvider()
        let tools = LocatedTools(claudePath: nil, environment: [:])
        #expect(throws: AgentLaunchError.self) { try provider.makeEndpoint(cwd: "/tmp", tools: tools) }
    }

    @Test("Claude 提供者返回进程内接入点并设置 CLAUDE_CODE_EXECUTABLE")
    func claudeEndpoint() throws {
        let tools = LocatedTools(claudePath: "/c", environment: ["PATH": "/bin"])
        guard case .inProcess(let config) = try ClaudeACPProvider().makeEndpoint(cwd: "/work", tools: tools) else {
            Issue.record("应为进程内接入点")
            return
        }
        #expect(config.executable == "/c")
        #expect(config.environment["CLAUDE_CODE_EXECUTABLE"] == "/c")
        #expect(config.environment["PATH"] == "/bin")
    }

    @Test("定位器按覆盖 > PATH 顺序找 claude,且不再依赖 node")
    func locateClaude() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("oma-locate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = dir.appendingPathComponent("claude")
        try Data("#!/bin/sh\n".utf8).write(to: fake)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let viaPath = ExecutableLocator.locate(environment: ["PATH": dir.path, "HOME": "/nonexistent"])
        #expect(viaPath.claudePath == fake.path && viaPath.isACPReady)
        let override = ExecutableLocator.locate(overrides: ["claude": fake.path], environment: ["PATH": "/nonexistent", "HOME": "/nonexistent"])
        #expect(override.claudePath == fake.path)
        let none = ExecutableLocator.locate(environment: ["PATH": "/nonexistent", "HOME": "/nonexistent"])
        #expect(none.claudePath == nil || none.claudePath?.hasPrefix("/opt/homebrew") == true || none.claudePath?.hasPrefix("/usr/local") == true)
    }

    @Test("通用 ACP 提供者在 PATH 中解析命令")
    func genericResolve() throws {
        let descriptor = AgentDescriptor(id: "x", name: "X", kind: .genericACP, command: "sh", args: ["-c", "true"])
        let tools = LocatedTools(environment: ["PATH": "/bin:/usr/bin"])
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
        let tools = LocatedTools(environment: ProcessInfo.processInfo.environment)
        let result = try await supervisor.start(tools: tools)
        #expect(result.agentName == "scripted-agent")
        let client = try #require(await supervisor.client)
        let setup = try await client.newSession(cwd: "/tmp")
        let stop = try await client.prompt(sessionId: setup.sessionId, content: [.text("hi")])
        #expect(stop == .endTurn)
        await supervisor.stop()
    }

    @Test("原生适配器经进程内传输完成握手(环境具备 claude 时)")
    func realAdapterHandshake() async throws {
        let env = ProcessInfo.processInfo.environment
        let tools = ExecutableLocator.locate(environment: env)
        guard tools.isACPReady else { return }
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
