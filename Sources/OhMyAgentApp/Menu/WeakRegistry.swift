// @author ixxxxoooo
// 弱引用注册表:保持登记顺序,登记 O(1)(按对象身份去重),失效条目在需要遍历时或增长过快时批量清理。
// 右键菜单锚点每行一个(侧栏/时间线上成百上千),旧实现每次登记都 `removeAll` 扫全表,
// 滚动时行不断挂载,登记总代价是 O(n²)。

import Foundation

/// 保序的弱引用注册表。
@MainActor
struct WeakRegistry<Element: AnyObject> {
    private struct Box { weak var object: Element? }

    private var boxes: [Box] = []
    /// 身份 → 盒子,用于 O(1) 去重(地址被复用时以 `===` 校验,不会误判)
    private var index: [ObjectIdentifier: Box] = [:]
    /// 上次清理后的存活数量,用于判断何时需要再次清理
    private var compactedCount = 0

    /// 当前登记的条目数(含尚未清理的失效项)。
    var rawCount: Int { boxes.count }

    /// 登记对象;已登记(同一对象)则忽略。
    /// - Parameter object: 要登记的对象
    mutating func insert(_ object: Element) {
        let id = ObjectIdentifier(object)
        if let existing = index[id], existing.object === object { return }
        let box = Box(object: object)
        index[id] = box
        boxes.append(box)
        // 失效项累积过多时清理一次,把总代价摊成 O(1)
        if boxes.count > max(256, compactedCount * 2) { compact() }
    }

    /// 清理已释放的条目。
    mutating func compact() {
        boxes.removeAll { $0.object == nil }
        index = index.filter { $0.value.object != nil }
        compactedCount = boxes.count
    }

    /// 按登记顺序返回存活的对象(顺带清理失效项)。
    mutating func alive() -> [Element] {
        compact()
        return boxes.compactMap(\.object)
    }
}
