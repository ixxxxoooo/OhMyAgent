// @author ixxxxoooo
// 选区:锚点 + 活动端(可反向),偏移为 UTF-16;撤销栈据此还原光标。

import Foundation

/// 单个选区。`anchor` 是选择起点,`head` 是光标所在的活动端(`head < anchor` 即反向选择)。
public struct Selection: Sendable, Hashable {
    /// 选择起点。
    public var anchor: Int
    /// 活动端(光标位置)。
    public var head: Int

    /// 创建选区(负偏移夹取为 0)。
    public init(anchor: Int, head: Int) {
        self.anchor = max(0, anchor)
        self.head = max(0, head)
    }

    /// 创建光标(空选区)。
    public init(caret: Int) { self.init(anchor: caret, head: caret) }

    /// 对应的文本区间。
    public var range: TextSpan { TextSpan(lower: min(anchor, head), upper: max(anchor, head)) }
    /// 是否为空选区(纯光标)。
    public var isEmpty: Bool { anchor == head }
    /// 是否反向(活动端在起点之前)。
    public var isReversed: Bool { head < anchor }
}
