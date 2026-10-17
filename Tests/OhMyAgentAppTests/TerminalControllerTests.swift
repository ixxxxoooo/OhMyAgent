// @author ixxxxoooo
// 终端控制器测试:真实 PTY 子进程的输出、退出码、环境净化、目录回退与按标签回收。

import AppKit
import DesignSystem
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

    @Test("环境:COLORFGBG 随背景明暗写入,并覆盖继承来的旧值")
    func colorFgBg() {
        setenv("COLORFGBG", "7;0", 1)
        defer { unsetenv("COLORFGBG") }
        #expect(TerminalController.environment(darkBackground: false).contains("COLORFGBG=0;15"))
        #expect(TerminalController.environment(darkBackground: true).contains("COLORFGBG=15;0"))
        #expect(!TerminalController.environment().contains { $0.hasPrefix("COLORFGBG=") })
    }

    @Test("OSC 11 背景色查询得到正确回复(OpenCode 靠它判断深浅)")
    func backgroundQueryAnswered() async {
        // 子进程切原始模式后发 OSC 11 查询,读取终端回复并以可见文本打印
        let script = "stty raw -echo; printf '\\033]11;?\\033\\\\'; IFS= read -r -s -t 5 -d '\\\\' r; stty sane; printf 'REPLY<%s>\\n' \"${r//$'\\033'/ESC}\""
        let controller = TerminalController(id: "osc11", directory: NSTemporaryDirectory(), executable: "/bin/bash", arguments: ["-c", script])
        await wait { controller.screenText.contains("REPLY<") && controller.screenText.contains(">") }
        let text = controller.screenText
        #expect(text.contains("REPLY<ESC]11;rgb:"), "实际输出:\(text)")
        // 回复里的背景色应与终端当前背景一致
        let expected = TerminalOSC.reply(code: 11, color: controller.view.nativeBackgroundColor)
            .replacingOccurrences(of: "\u{1b}", with: "ESC").replacingOccurrences(of: "ESC\\", with: "")
        #expect(text.contains(expected), "期望包含 \(expected),实际:\(text)")
    }

    @Test("OSC 颜色:回复格式与规格解析")
    func oscFormatAndParse() {
        let reply = TerminalOSC.reply(code: 11, color: NSColor(srgbRed: 1, green: 0, blue: 0.5, alpha: 1))
        #expect(reply == "\u{1b}]11;rgb:ffff/0000/8000\u{1b}\\")
        #expect(TerminalOSC.parse("rgb:ff/00/80")?.usingColorSpace(.sRGB)?.redComponent == 1)
        #expect(TerminalOSC.parse("rgb:f/0/8") != nil)
        #expect(abs((TerminalOSC.parse("#336699")?.usingColorSpace(.sRGB)?.blueComponent ?? 0) - 0.6) < 0.01)
        #expect(TerminalOSC.parse("rgb:zz/00/00") == nil && TerminalOSC.parse("?") == nil && TerminalOSC.parse("#12") == nil)
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
