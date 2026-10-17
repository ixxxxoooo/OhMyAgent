// @author ixxxxoooo
// Agent 终端辅助测试:环境标记、输出清洗、沙箱配置与(可用时)真实沙箱拦截。

import Foundation
import Testing

@testable import AgentHost

@Suite("Agent 终端辅助")
struct TerminalSandboxTests {
    @Test("Agent 终端注入 OHMYAGENT_AGENT 标记")
    func markerInjected() async throws {
        let terminals = TerminalManager(workspace: NSTemporaryDirectory())
        let id = try await terminals.create(command: "sh", args: ["-c", "echo marker=$OHMYAGENT_AGENT"], env: [:], cwd: nil, outputByteLimit: nil)
        let final = try await terminals.waitForExit(id)
        #expect(final.output.contains("marker=1"))
        #expect(AgentEnvironment.marked([:])[AgentEnvironment.marker] == "1")
    }

    @Test("清洗:去掉 OSC/括号粘贴/光标控制,保留 SGR 颜色")
    func sanitize() {
        let raw = "\u{1B}]0;title\u{07}\u{1B}]133;A\u{1B}\\\u{1B}[?2004hhello \u{1B}[31mred\u{1B}[0m\u{1B}[2K\u{1B}[1Aworld\u{07}\u{08}\n\u{1B}[?2004l"
        let cleaned = TerminalOutputSanitizer.clean(raw)
        #expect(cleaned == "hello \u{1B}[31mred\u{1B}[0mworld\n")
        #expect(TerminalOutputSanitizer.clean("普通 text\n\tok") == "普通 text\n\tok")
    }

    @Test("沙箱配置:SBPL 含工作区白名单与网络档位")
    func profile() {
        let off = TerminalSandbox.profile(workspace: "/tmp/ws", config: TerminalSandboxConfig(enabled: true, network: .off, writablePaths: ["/tmp/extra"]), home: "/Users/x")
        #expect(off.contains("(deny file-write*)"))
        #expect(off.contains("/tmp/extra") || off.contains("/private/tmp/extra"))
        #expect(off.contains("(deny network*)"))
        let all = TerminalSandbox.profile(workspace: "/tmp/ws", config: TerminalSandboxConfig(enabled: true, network: .all), home: "/Users/x")
        #expect(!all.contains("(deny network*)"))
        let local = TerminalSandbox.profile(workspace: "/tmp/ws", config: TerminalSandboxConfig(enabled: true, network: .local), home: "/Users/x")
        #expect(local.contains("localhost:*"))
    }

    @Test(".oma/sandbox.json 覆盖网络档位并追加可写目录")
    func resolveOverrides() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("oma-sbx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".oma"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(#"{"network":"all","additionalWritablePaths":["build","/opt/cache"]}"#.utf8).write(to: dir.appendingPathComponent(".oma/sandbox.json"))
        let resolved = TerminalSandbox.resolve(base: TerminalSandboxConfig(enabled: true, network: .off), workspace: dir.path)
        #expect(resolved.network == .all)
        #expect(resolved.writablePaths == [dir.path + "/build", "/opt/cache"])
        // 文件缺失时保持基础配置
        let base = TerminalSandboxConfig(enabled: true, network: .off)
        #expect(TerminalSandbox.resolve(base: base, workspace: "/nonexistent-oma") == base)
    }

    @Test("拦截识别:仅在非零退出且含沙箱特征时成立")
    func looksBlocked() {
        #expect(TerminalSandbox.looksBlocked(output: "touch: x: Operation not permitted", exitCode: 1))
        #expect(!TerminalSandbox.looksBlocked(output: "Operation not permitted", exitCode: 0))
        #expect(!TerminalSandbox.looksBlocked(output: "all good", exitCode: 1))
    }

    /// 真实沙箱:工作区可写,家目录下不可写。环境不允许嵌套沙箱时跳过。
    @Test("真实沙箱拦截工作区外写入")
    func realSandbox() async throws {
        guard TerminalSandbox.isAvailable else { return }
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: TerminalSandbox.executable)
        probe.arguments = ["-p", "(version 1)(allow default)", "/usr/bin/true"]
        probe.standardError = FileHandle.nullDevice
        try probe.run()
        probe.waitUntilExit()
        guard probe.terminationStatus == 0 else { return }

        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("oma-ws-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let outside = NSHomeDirectory() + "/.oma-sandbox-probe-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: outside) }

        let terminals = TerminalManager(workspace: workspace.path, sandbox: { TerminalSandboxConfig(enabled: true, network: .off) })
        let inside = try await terminals.create(command: "sh", args: ["-c", "echo ok > inside.txt && echo wrote"], env: [:], cwd: nil, outputByteLimit: nil)
        let insideResult = try await terminals.waitForExit(inside)
        #expect(insideResult.exitCode == 0, "输出:\(insideResult.output)")
        #expect(await terminals.isSandboxed(inside))

        let blocked = try await terminals.create(command: "sh", args: ["-c", "echo no > '\(outside)'"], env: [:], cwd: nil, outputByteLimit: nil)
        let blockedResult = try await terminals.waitForExit(blocked)
        #expect(blockedResult.exitCode != 0)
        #expect(!FileManager.default.fileExists(atPath: outside))
        #expect(TerminalSandbox.looksBlocked(output: blockedResult.output, exitCode: blockedResult.exitCode))

        // 放行一次:下一条不进沙箱,之后恢复
        await terminals.allowUnsandboxedOnce()
        let bypass = try await terminals.create(command: "sh", args: ["-c", "echo yes > '\(outside)'"], env: [:], cwd: nil, outputByteLimit: nil)
        let bypassResult = try await terminals.waitForExit(bypass)
        #expect(!(await terminals.isSandboxed(bypass)))
        #expect(bypassResult.exitCode == 0)
        let again = try await terminals.create(command: "true", args: [], env: [:], cwd: nil, outputByteLimit: nil)
        #expect(await terminals.isSandboxed(again))
    }
}
