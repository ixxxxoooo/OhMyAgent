// @author ixxxxoooo
// 交互终端偏好:读取与夹取、光标样式映射、Shell 解析、起始目录,以及对终端视图的热更新。

import AppKit
import ChatKit
import Foundation
import SwiftTerm
import Testing

@testable import OhMyAgentApp

@MainActor
@Suite("终端偏好")
struct TerminalPrefsTests {
    private func makeDefaults() -> UserDefaults {
        let name = "oma.test.terminal.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name) ?? .standard
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("缺省值与夹取:字号 9–24、回滚 500–100000")
    func defaultsAndClamping() {
        let defaults = makeDefaults()
        #expect(TerminalPrefs.load(defaults) == TerminalPrefs())
        defaults.set(99.0, forKey: ClientPrefs.Key.terminalShellFontSize)
        defaults.set(10, forKey: ClientPrefs.Key.terminalScrollback)
        let clamped = TerminalPrefs.load(defaults)
        #expect(clamped.fontSize == 24 && clamped.scrollback == 500)
        defaults.set(5.0, forKey: ClientPrefs.Key.terminalShellFontSize)
        defaults.set(9_999_999, forKey: ClientPrefs.Key.terminalScrollback)
        let low = TerminalPrefs.load(defaults)
        #expect(low.fontSize == 9 && low.scrollback == 100_000)
    }

    @Test("光标形状与闪烁映射到 SwiftTerm 样式")
    func cursorStyle() {
        var prefs = TerminalPrefs()
        prefs.cursorShape = .bar; prefs.cursorBlink = false
        #expect(prefs.cursorStyle == .steadyBar)
        prefs.cursorShape = .underline; prefs.cursorBlink = true
        #expect(prefs.cursorStyle == .blinkUnderline)
        prefs.cursorShape = .block
        #expect(prefs.cursorStyle == .blinkBlock)
    }

    @Test("Shell 解析:自定义可执行路径优先,无效路径回退 $SHELL,再回退 zsh;登录参数")
    func shellResolution() {
        var prefs = TerminalPrefs()
        #expect(prefs.resolvedShell(environment: ["SHELL": "/bin/bash"]) == "/bin/bash")
        #expect(prefs.resolvedShell(environment: [:]) == "/bin/zsh")
        prefs.shellPath = "/bin/sh"
        #expect(prefs.resolvedShell(environment: ["SHELL": "/bin/bash"]) == "/bin/sh")
        prefs.shellPath = "/不存在/shell"
        #expect(prefs.resolvedShell(environment: ["SHELL": "/bin/bash"]) == "/bin/bash")
        #expect(prefs.shellArguments == ["-l"])
        prefs.loginShell = false
        #expect(prefs.shellArguments.isEmpty)
    }

    @Test("起始目录:项目根目录或主目录,无项目时回退主目录")
    func startDirectory() {
        var prefs = TerminalPrefs()
        #expect(prefs.startDirectoryPath(project: "/tmp/p") == "/tmp/p")
        #expect(prefs.startDirectoryPath(project: nil) == NSHomeDirectory())
        #expect(prefs.startDirectoryPath(project: "") == NSHomeDirectory())
        prefs.startDirectory = .home
        #expect(prefs.startDirectoryPath(project: "/tmp/p") == NSHomeDirectory())
    }

    @Test("偏好应用到终端视图:字号、光标、Option 键热更新")
    func appliesToView() {
        var prefs = TerminalPrefs()
        prefs.fontSize = 16
        let controller = TerminalController(id: "prefs1", directory: NSTemporaryDirectory(), executable: "/bin/sh", arguments: ["-c", "true"], prefs: prefs)
        #expect(controller.view.font.pointSize == 16)
        prefs.fontSize = 20
        prefs.optionAsMeta = false
        prefs.cursorShape = .bar
        controller.applyPrefs(prefs, initial: false)
        #expect(controller.view.font.pointSize == 20)
        #expect(controller.view.optionAsMetaKey == false)
    }

    @Test("回滚行数在创建时生效:超出默认 500 行的早期输出仍可见")
    func scrollbackApplied() async {
        var prefs = TerminalPrefs()
        prefs.scrollback = 5_000
        let controller = TerminalController(id: "prefs2", directory: NSTemporaryDirectory(), executable: "/bin/sh", arguments: ["-c", "i=1; while [ $i -le 1500 ]; do echo line-$i-end; i=$((i+1)); done"], prefs: prefs)
        for _ in 0..<100 where controller.isRunning || !controller.screenText.contains("line-1500-end") { try? await Task.sleep(for: .milliseconds(50)) }
        #expect(controller.screenText.contains("line-3-end"), "回滚行数设为 5000 时,第 3 行应仍在缓冲里")
    }
}
