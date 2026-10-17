// @author ixxxxoooo
// 中央搜索窗键盘指令解析测试:底部提示的 ↑↓ / ↵ / ⇥ / esc 必须真正对应到指令。

import AppKit
import Testing
@testable import OhMyAgentApp

@Suite("HubKeyResolver")
struct HubKeyTests {
    private typealias Code = HubKeyResolver.Code

    @Test("上下方向键移动选中项")
    func arrows() {
        #expect(HubKeyResolver.resolve(keyCode: Code.downArrow, modifiers: [], composing: false) == .move(1))
        #expect(HubKeyResolver.resolve(keyCode: Code.upArrow, modifiers: [], composing: false) == .move(-1))
        #expect(HubKeyResolver.resolve(keyCode: Code.keyN, modifiers: .control, composing: false) == .move(1))
        #expect(HubKeyResolver.resolve(keyCode: Code.keyP, modifiers: .control, composing: false) == .move(-1))
    }

    @Test("Tab 切换分类,Shift+Tab 反向")
    func tab() {
        #expect(HubKeyResolver.resolve(keyCode: Code.tab, modifiers: [], composing: false) == .switchSegment(1))
        #expect(HubKeyResolver.resolve(keyCode: Code.tab, modifiers: .shift, composing: false) == .switchSegment(-1))
    }

    @Test("回车执行,Esc 关闭")
    func submitAndDismiss() {
        #expect(HubKeyResolver.resolve(keyCode: Code.returnKey, modifiers: [], composing: false) == .submit)
        #expect(HubKeyResolver.resolve(keyCode: Code.keypadEnter, modifiers: [], composing: false) == .submit)
        #expect(HubKeyResolver.resolve(keyCode: Code.escape, modifiers: [], composing: false) == .dismiss)
    }

    @Test("输入法组字期间一律放行")
    func composingPassesThrough() {
        for code in [Code.downArrow, Code.upArrow, Code.tab, Code.returnKey, Code.escape] {
            #expect(HubKeyResolver.resolve(keyCode: code, modifiers: [], composing: true) == nil)
        }
    }

    @Test("带 ⌘/⌥ 的组合键不被吞掉")
    func modifiedKeysPassThrough() {
        #expect(HubKeyResolver.resolve(keyCode: Code.returnKey, modifiers: .command, composing: false) == nil)
        #expect(HubKeyResolver.resolve(keyCode: Code.downArrow, modifiers: .option, composing: false) == nil)
        #expect(HubKeyResolver.resolve(keyCode: Code.tab, modifiers: .command, composing: false) == nil)
    }
}
