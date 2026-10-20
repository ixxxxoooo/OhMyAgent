// @author ixxxxoooo
// 时间线空白自愈:偶发「会话是空白的,鼠标滚一下才恢复显示」。
// 成因:`LazyVStack` 只在滚动容器的可见区域变化时才物化行;标签从隐藏恢复可见、容器尺寸变化、
// 历史回放结束等场景里内容高度变了但没有产生可见区域变化通知,视口落在尚未物化的区域,表现为空白。
// 这里记录滚动几何,在「视口内可见条目数为 0 而内容非空」时程序化轻推一次滚动位置,触发行物化。

import Foundation

/// 空白检测与防抖(不参与观察:几何每帧都在变)。
@MainActor
final class TimelineBlankGuard {
    /// 最近一次滚动几何
    var offsetY: CGFloat = 0
    var contentHeight: CGFloat = 0
    var containerHeight: CGFloat = 0
    /// 防抖任务
    private var task: Task<Void, Never>?
    /// 上次轻推时间(限流:避免异常情况下反复轻推)
    private var lastNudge = Date.distantPast

    /// 记录几何,返回容器尺寸是否有明显变化(此时应安排一次检查)。
    /// - Parameters:
    ///   - offsetY: 滚动偏移
    ///   - contentHeight: 内容高度
    ///   - containerHeight: 视口高度
    /// - Returns: 视口高度变化超过 1pt,或内容高度从 0 变为非 0
    @discardableResult
    func record(offsetY: CGFloat, contentHeight: CGFloat, containerHeight: CGFloat) -> Bool {
        let resized = abs(containerHeight - self.containerHeight) > 1 || (self.contentHeight <= 0 && contentHeight > 0)
        self.offsetY = offsetY
        self.contentHeight = contentHeight
        self.containerHeight = containerHeight
        return resized
    }

    /// 延迟执行一次检查(重复安排会取消上一次,等几何稳定后再查)。
    /// - Parameters:
    ///   - delay: 延迟
    ///   - action: 检查并在需要时轻推;返回 true 表示执行了轻推
    func schedule(after delay: Duration = .milliseconds(400), _ action: @escaping @MainActor () async -> Bool) {
        task?.cancel()
        task = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            guard Date().timeIntervalSince(self.lastNudge) > 1 else { return }
            if await action() { self.lastNudge = Date() }
        }
    }

    /// 取消待执行的检查。
    func cancel() {
        task?.cancel()
        task = nil
    }

    /// 是否空白:有内容、视口有高度,但没有任何可见条目。
    /// - Parameters:
    ///   - visibleCount: 可见条目数(-1 = 未上报,按 0 处理)
    ///   - hasEntries: 时间线是否有条目
    static func isBlank(visibleCount: Int, hasEntries: Bool, containerHeight: CGFloat) -> Bool {
        hasEntries && containerHeight > 0 && visibleCount <= 0
    }
}
