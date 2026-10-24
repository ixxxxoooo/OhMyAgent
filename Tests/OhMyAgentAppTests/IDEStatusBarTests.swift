// @author ixxxxoooo
// IDE 状态栏文案:缩进方式识别、光标行 blame。

import Foundation
import Testing
@testable import OhMyAgentApp

@Suite("IDE 状态栏文案")
@MainActor
struct IDEStatusBarTests {
    @Test("缩进识别:4 空格")
    func fourSpaces() {
        #expect(IDEStatusBar.indentationLabel(of: "a {\n    b {\n        c\n    }\n}\n").contains("4"))
    }

    @Test("缩进识别:2 空格")
    func twoSpaces() {
        #expect(IDEStatusBar.indentationLabel(of: "a {\n  b {\n    c\n  }\n}\n").contains("2"))
    }

    @Test("缩进识别:制表符")
    func tabs() {
        #expect(IDEStatusBar.indentationLabel(of: "a {\n\tb\n\tc\n}\n") == String(localized: "制表符"))
    }

    @Test("blame 文案:没有数据为 nil")
    func blameMissing() {
        #expect(IDEStatusBar.blameNote(nil, line: 1) == nil)
        #expect(IDEStatusBar.blameNote([], line: 1) == nil)
    }
}
