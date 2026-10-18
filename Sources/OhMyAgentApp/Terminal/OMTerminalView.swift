// @author ixxxxoooo
// 终端渲染视图:在 SwiftTerm 的 `TerminalView` 上拦截退化尺寸。
// SwiftUI 卸载/重新挂载宿主(切换终端标签)时会把视图尺寸先置为 (0, 0) 再恢复,
// SwiftTerm 不做保护,会把整个回滚缓冲区先重排到 0 列(`reflowNarrower`)再重排回来,
// 一次切换两次全量重排,缓冲区越大越卡。忽略这类尺寸即可避免,正常的尺寸变化不受影响。

import AppKit
import SwiftTerm

final class OMTerminalView: TerminalView {
    /// 小于这个值的宽或高视为退化尺寸(不足一个字符),不应用。
    static let minimumSide: CGFloat = 16

    /// 是否应用该尺寸。
    /// - Parameter size: SwiftUI/AppKit 给出的新尺寸
    /// - Returns: 宽高都不小于一个字符时为 true
    static func accepts(_ size: NSSize) -> Bool {
        size.width >= minimumSide && size.height >= minimumSide
    }

    override func setFrameSize(_ newSize: NSSize) {
        guard Self.accepts(newSize) else { return }
        super.setFrameSize(newSize)
    }
}
