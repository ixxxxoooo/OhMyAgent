// @author ixxxxoooo
// 终端渲染视图:在 SwiftTerm 的 `TerminalView` 上拦截退化尺寸与实时缩放期间的逐帧重排。
// 1. SwiftUI 卸载/重新挂载宿主(切换终端标签)时会把视图尺寸先置为 (0, 0) 再恢复,
//    SwiftTerm 不做保护,会把整个回滚缓冲区先重排到 0 列(`reflowNarrower`)再重排回来,
//    一次切换两次全量重排,缓冲区越大越卡。忽略这类尺寸即可避免,正常的尺寸变化不受影响。
// 2. 窗口实时缩放 / 拖分栏期间保持原尺寸(只裁剪),结束时一次性应用,见 `LiveResizeGate`。

import AppKit
import SwiftTerm
import WorkbenchKit

final class OMTerminalView: TerminalView {
    /// 小于这个值的宽或高视为退化尺寸(不足一个字符),不应用。
    static let minimumSide: CGFloat = 16

    /// 是否应用该尺寸。
    /// - Parameter size: SwiftUI/AppKit 给出的新尺寸
    /// - Returns: 宽高都不小于一个字符时为 true
    static func accepts(_ size: NSSize) -> Bool {
        size.width >= minimumSide && size.height >= minimumSide
    }

    /// 实时缩放门控(窗口缩放或面板分隔条拖动期间暂存尺寸)。
    private var gate = LiveResizeGate()
    /// 停稳兜底任务:门控期间一段时间没有新尺寸就应用暂存值。
    private var settleTask: Task<Void, Never>?

    /// 当前是否处于窗口实时缩放或分隔条拖动中。
    private var isLiveResizing: Bool {
        window?.inLiveResize == true || PanelDragState.shared.isDragging
    }

    override func setFrameSize(_ newSize: NSSize) {
        guard Self.accepts(newSize) else { return }
        guard let size = gate.submit(newSize, gated: isLiveResizing, current: frame.size) else {
            scheduleSettle()
            return
        }
        settleTask?.cancel()
        settleTask = nil
        super.setFrameSize(size)
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        flushPending()
    }

    /// 门控期间安排「停稳」兜底:~100ms 内没有新尺寸到达就应用暂存值(拖动停住或结束通知丢失时也能收敛)。
    private func scheduleSettle() {
        settleTask?.cancel()
        settleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: LiveResizeGate.settleDelay)
            guard !Task.isCancelled, let self else { return }
            self.flushPending()
        }
    }

    /// 应用暂存的最新尺寸(一次性重排)。
    private func flushPending() {
        settleTask?.cancel()
        settleTask = nil
        if let size = gate.flush(current: frame.size) { super.setFrameSize(size) }
    }
}
