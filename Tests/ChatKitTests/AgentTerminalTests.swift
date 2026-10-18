// @author ixxxxoooo
// Agent 终端端到端:脚本 Agent 经 `_meta.terminal_*` 报告 Bash,SessionModel 镜像成外部终端会话,
// 后台命令跟读输出文件并在任务结束时收尾。

import ACPKit
import Foundation
import Testing
@testable import ChatKit

@MainActor
@Suite("Agent 终端(后台命令)")
struct AgentTerminalTests {
    @Test("声明 terminal_output 能力;关闭开关后不声明")
    func capability() {
        var features = ClientFeatures()
        #expect(features.extraCapabilities["_meta"]?["terminal_output"]?.boolValue == true)
        features.agentTerminalOutput = false
        #expect(features.extraCapabilities["_meta"] == nil)
    }

    @Test("演示场景:前台命令带输出与退出码,后台命令实时跟读并在结束时收尾")
    func shellScenario() async throws {
        let ws = try M3ScenarioTests.tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let model = try await M3ScenarioTests.readyModel(workspace: ws)
        model.send("#demo-tools-shell")
        let started = await SessionModelTests.wait(timeout: .seconds(30)) { model.terminals.values.contains { $0.command == "npm run dev" } }
        #expect(started, "后台命令应登记为外部终端")
        let bg = try #require(model.terminals.values.first { $0.command == "npm run dev" })
        #expect(bg.isExternal)
        #expect(await SessionModelTests.wait(timeout: .seconds(30)) { bg.isBackground && bg.output.contains("VITE") })
        #expect(bg.isRunning, "后台命令还在运行,工具已完成不能收尾它")
        #expect(await SessionModelTests.wait(timeout: .seconds(60)) { !bg.isRunning })
        #expect(bg.output.contains("hmr update"), "收尾前必须把输出读完")
        #expect(bg.output.contains("中文日志也能正常显示"))
        // 前台命令:输出来自 _meta,退出码来自 terminal_exit
        let failed = try #require(model.terminals.values.first { $0.command.hasPrefix("cat missing.txt") })
        #expect(!failed.isRunning && failed.exitCode == 1 && failed.output.contains("No such file"))
        model.shutdown()
    }
}
