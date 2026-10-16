// @author ixxxxoooo
// 终端控制器测试:真实 PTY 子进程的输出、退出码、环境净化、目录回退与按标签回收。

import Foundation
import Testing

@testable import OhMyAgentApp

@MainActor
@Suite("终端控制器")
struct TerminalControllerTests {
    /// 等待条件成立(最多约 5 秒)。
    private func wait(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<100 where !condition() { try? await Task.sleep(for: .milliseconds(50)) }
    }

    @Test("执行命令后输出进入终端缓冲并得到退出码")
    func runsCommand() async {
        let controller = TerminalController(id: "t1", directory: NSTemporaryDirectory(), executable: "/bin/sh", arguments: ["-c", "echo oma-term-ok; exit 3"])
        await wait { !controller.isRunning && controller.screenText.contains("oma-term-ok") }
        #expect(controller.screenText.contains("oma-term-ok"))
        #expect(controller.exitCode == 3)
        #expect(!controller.isRunning)
    }

    @Test("在指定目录启动;不存在的目录退回主目录")
    func workingDirectory() async {
        let dir = NSTemporaryDirectory()
        let controller = TerminalController(id: "t2", directory: dir, executable: "/bin/sh", arguments: ["-c", "pwd -P"])
        await wait { !controller.isRunning && !controller.screenText.isEmpty }
        let real = URL(fileURLWithPath: dir).resolvingSymlinksInPath().path
        #expect(controller.screenText.contains(real.hasSuffix("/") ? String(real.dropLast()) : real))
        let fallback = TerminalController(id: "t3", directory: "/不存在/目录", executable: "/bin/sh", arguments: ["-c", "true"])
        #expect(fallback.directory == NSHomeDirectory())
    }

    @Test("交互输入:send 写入 shell 并回显")
    func sendsInput() async {
        let controller = TerminalController(id: "t4", directory: NSTemporaryDirectory(), executable: "/bin/sh", arguments: [])
        #expect(controller.isRunning)
        controller.send("echo from-send-$((20+22))\r")
        await wait { controller.screenText.contains("from-send-42") }
        #expect(controller.screenText.contains("from-send-42"))
        controller.send("exit 0\r")
        await wait { !controller.isRunning }
        #expect(!controller.isRunning)
    }

    @Test("环境:设置终端能力并过滤 OMA_/ANTHROPIC_ 变量")
    func environment() {
        setenv("OMA_TEST_SECRET", "x", 1)
        setenv("ANTHROPIC_AUTH_TOKEN", "y", 1)
        defer { unsetenv("OMA_TEST_SECRET"); unsetenv("ANTHROPIC_AUTH_TOKEN") }
        let env = TerminalController.environment(extra: ["FOO": "bar"])
        #expect(env.contains("TERM=xterm-256color"))
        #expect(env.contains("COLORTERM=truecolor"))
        #expect(env.contains("FOO=bar"))
        #expect(!env.contains { $0.hasPrefix("OMA_") || $0.hasPrefix("ANTHROPIC_") })
    }

    @Test("仓库按标签回收:关闭后终止进程,底部面板终端常驻")
    func storePrune() async {
        let store = TerminalStore.shared
        store.register(id: "tab-a", directory: NSTemporaryDirectory())
        let a = store.controller(for: "tab-a", fallbackDirectory: NSHomeDirectory())
        let bottom = store.controller(for: "bottom:/x", fallbackDirectory: NSTemporaryDirectory())
        #expect(a.isRunning)
        store.prune(keeping: [])
        await wait { !a.isRunning }
        #expect(!a.isRunning)
        #expect(store.controllers["tab-a"] == nil)
        #expect(store.controllers["bottom:/x"] != nil)
        store.remove("bottom:/x")
        await wait { !bottom.isRunning }
    }
}

@Suite("waitpid 状态解码")
struct WaitStatusTests {
    @Test("正常退出取高字节,信号终止为 nil")
    func decode() {
        #expect(TerminalController.decodeWaitStatus(3 << 8) == 3)
        #expect(TerminalController.decodeWaitStatus(0) == 0)
        #expect(TerminalController.decodeWaitStatus(9) == nil)
    }
}
