// @author ixxxxoooo
// 面板内标签/图标顺序的纯逻辑(工具栏文件/搜索/Git、底部面板终端/输出的拖拽换序),无视图。

import Foundation

/// 面板内条目顺序的规整与移动。
public enum PaneOrder {
    /// 规整顺序:去重、丢弃不可用项、把缺失项按默认顺序补到末尾。
    /// - Parameters:
    ///   - order: 待规整的顺序
    ///   - all: 全部可用项(默认顺序)
    /// - Returns: 包含且仅包含 `all` 中每项一次的顺序
    public static func normalized<T: Hashable>(_ order: [T], all: [T]) -> [T] {
        var seen = Set<T>()
        let kept = order.filter { all.contains($0) && seen.insert($0).inserted }
        return kept + all.filter { !seen.contains($0) }
    }

    /// 把 `item` 移到 `target` 所在位置(拖到谁身上就占据谁的位置,其余顺延)。
    /// - Parameters:
    ///   - order: 当前顺序
    ///   - item: 被拖动项
    ///   - target: 落点所在项;nil 表示移到末尾
    /// - Returns: 新顺序;item 不在顺序中或与 target 相同时原样返回
    public static func moved<T: Hashable>(_ order: [T], item: T, onto target: T?) -> [T] {
        guard item != target, let from = order.firstIndex(of: item) else { return order }
        var result = order
        result.remove(at: from)
        if let target, let to = order.firstIndex(of: target) {
            result.insert(item, at: to)
        } else {
            result.append(item)
        }
        return result
    }
}
