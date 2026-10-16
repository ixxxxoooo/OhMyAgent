// @author ixxxxoooo
// 空会话登记表测试:新建未使用的会话被隐藏,首条消息后恢复可见;重启后仍保持登记。

import Foundation
import Testing

@testable import ChatKit

@MainActor
@Suite("空会话登记", .serialized)
struct EmptySessionRegistryTests {
    @Test("隐藏与恢复")
    func hideAndUnhide() {
        EmptySessionRegistry.resetForTesting()
        defer { EmptySessionRegistry.resetForTesting() }
        #expect(!EmptySessionRegistry.isHidden("s1"))
        EmptySessionRegistry.hide("s1")
        #expect(EmptySessionRegistry.isHidden("s1"))
        EmptySessionRegistry.unhide("s1")
        #expect(!EmptySessionRegistry.isHidden("s1"))
        EmptySessionRegistry.hide("")   // 空串忽略
        #expect(!EmptySessionRegistry.isHidden(""))
    }

    @Test("持久化到 UserDefaults 且数量封顶 500")
    func persistenceAndLimit() {
        EmptySessionRegistry.resetForTesting()
        defer { EmptySessionRegistry.resetForTesting() }
        for index in 0..<520 { EmptySessionRegistry.hide("id\(index)") }
        #expect(!EmptySessionRegistry.isHidden("id0"))      // 最旧的被淘汰
        #expect(EmptySessionRegistry.isHidden("id519"))
        let stored = UserDefaults.standard.stringArray(forKey: "session.emptyIDs") ?? []
        #expect(stored.count == 500 && stored.last == "id519")
    }
}
