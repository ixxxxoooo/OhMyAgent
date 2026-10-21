// @author ixxxxoooo
// IDEKit 骨架:确认模块可被测试 target 链接。

import Testing
@testable import IDEKit

@Suite("IDEKit 骨架")
struct IDEKitModuleTests {
    @Test("模块名固定")
    func moduleName() {
        #expect(IDEKitModule.name == "IDEKit")
    }
}
