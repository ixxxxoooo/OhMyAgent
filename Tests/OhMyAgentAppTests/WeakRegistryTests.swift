// @author ixxxxoooo
// 弱引用注册表测试:保序、同一对象去重、释放后清理、大量登记不退化。

import Foundation
import Testing
@testable import OhMyAgentApp

@MainActor
@Suite("弱引用注册表")
struct WeakRegistryTests {
    private final class Item { let tag: Int; init(_ tag: Int) { self.tag = tag } }

    @Test("按登记顺序返回,重复登记同一对象只保留一份")
    func orderAndDedupe() {
        var registry = WeakRegistry<Item>()
        let a = Item(1), b = Item(2), c = Item(3)
        registry.insert(a); registry.insert(b); registry.insert(c); registry.insert(b)
        #expect(registry.alive().map(\.tag) == [1, 2, 3])
    }

    @Test("对象释放后被清理,不会被强引用持有")
    func releasesObjects() {
        var registry = WeakRegistry<Item>()
        let keep = Item(1)
        registry.insert(keep)
        do {
            let temp = Item(2)
            registry.insert(temp)
            #expect(registry.rawCount == 2)
        }
        #expect(registry.alive().map(\.tag) == [1])
        #expect(registry.rawCount == 1)
    }

    @Test("大量登记 + 大量失效项时自动清理,原始条目数有界")
    func boundedGrowth() {
        var registry = WeakRegistry<Item>()
        let keep = (0..<10).map(Item.init)
        keep.forEach { registry.insert($0) }
        for index in 0..<5000 { registry.insert(Item(1000 + index)) }
        // 失效项会被摊销清理:原始条目数远小于累计登记数
        #expect(registry.rawCount < 1200)
        #expect(registry.alive().count == 10)
    }
}
