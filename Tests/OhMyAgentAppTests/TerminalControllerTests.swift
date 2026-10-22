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

    @Test("弃用控制器会清空缓冲并把回滚设为 0(SwiftTerm 的 Terminal↔Buffer 循环引用让对象本身回收不了)")
    func disposeReleasesBuffers() async {
        let controller = TerminalController(id: "t-dispose", directory: NSTemporaryDirectory(), executable: "/bin/sh", arguments: ["-c", "echo oma-dispose-ok; exit 0"])
        await wait { !controller.isRunning && controller.screenText.contains("oma-dispose-ok") }
        #expect(controller.screenText.contains("oma-dispose-ok"))
        controller.dispose()
        #expect(controller.view.getTerminal().options.scrollback == 0)
        #expect(!controller.screenText.contains("oma-dispose-ok"))
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

    @Test("切换标签时视图被置零尺寸不触发重排:列数保持,回滚内容不变")
    func ignoresDegenerateSize() async {
        let controller = TerminalController(id: "t-size", directory: NSTemporaryDirectory(), executable: "/bin/sh", arguments: ["-c", "seq 1 500"])
        controller.view.setFrameSize(NSSize(width: 800, height: 300))
        await wait { !controller.isRunning && controller.screenText.contains("500") }
        let terminal = controller.view.getTerminal()
        let cols = terminal.cols, rows = terminal.rows
        #expect(cols > 20 && rows > 5)
        controller.view.setFrameSize(.zero)
        controller.view.setFrameSize(NSSize(width: 4, height: 300))
        #expect(terminal.cols == cols && terminal.rows == rows, "退化尺寸必须被忽略")
        #expect(controller.view.frame.size == NSSize(width: 800, height: 300))
        controller.view.setFrameSize(NSSize(width: 800, height: 300))
        #expect(terminal.cols == cols, "同样尺寸再次设置不变")
        controller.view.setFrameSize(NSSize(width: 500, height: 300))
        #expect(terminal.cols < cols, "正常的尺寸变化仍然生效")
        #expect(OMTerminalView.accepts(NSSize(width: 100, height: 40)) && !OMTerminalView.accepts(.zero))
    }

    @Test("宽字符:中英混排按双宽占两列,后续字符不错位")
    func wideCharacters() async {
        let controller = TerminalController(id: "t-wide", directory: NSTemporaryDirectory(), executable: "/bin/sh", arguments: ["-c", "printf 'ab你c是d谁\\n'"], environment: ["LANG": "en_US.UTF-8"])
        await wait { !controller.isRunning && controller.screenText.contains("谁") }
        // 缓冲导出时宽字符的第二格是 NUL 占位,去掉后顺序必须一致
        #expect(controller.screenText.filter { !$0.isWhitespace && $0 != "\0" }.contains("ab你c是d谁"))
        let terminal = controller.view.getTerminal()
        // a b [你 占 2 列] c [是 占 2 列] d [谁 占 2 列]:列 2 是汉字、列 3 是其占位格,列 4 是 c
        #expect(terminal.getCharData(col: 2, row: 0)?.width == 2)
        #expect(terminal.getCharData(col: 4, row: 0)?.getCharacter() == "c")
        #expect(terminal.getCharData(col: 7, row: 0)?.getCharacter() == "d")
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
