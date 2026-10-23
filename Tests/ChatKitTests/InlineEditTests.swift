// @author ixxxxoooo
// 行内编辑(⌘K)的提示词构造、输出清洗与演示改写。

import Foundation
import Testing
@testable import ChatKit

@Suite("InlineEdit")
struct InlineEditTests {
    @Test("清洗:去掉整体代码围栏,保留缩进")
    func cleanFence() {
        #expect(InlineEdit.clean("```swift\n    let a = 1\n```") == "    let a = 1")
        #expect(InlineEdit.clean("let a = 1\n```inner```") == "let a = 1\n```inner```")
        #expect(InlineEdit.clean("   \n") == nil)
        #expect(InlineEdit.clean("<selection>x</selection>") == "x")
    }

    @Test("用户消息含文件名、指令与选区")
    func userMessage() {
        let text = InlineEdit.userMessage(instruction: " 改名 ", path: "/a/b/C.swift", selected: "let x = 1", before: "", after: "tail")
        #expect(text.contains("C.swift"))
        #expect(text.contains("指令:改名"))
        #expect(text.contains("<selection>\nlet x = 1\n</selection>"))
        #expect(!text.contains("<before>"))
        #expect(text.contains("<after>\ntail\n</after>"))
    }

    @Test("演示改写:第二行插入带缩进的注释")
    func demoRewrite() {
        let result = InlineEdit.demoRewrite(selected: "    a\n    b", instruction: "加注释")
        #expect(result == "    a\n    // 已按指令修改:加注释\n    b")
    }
}
