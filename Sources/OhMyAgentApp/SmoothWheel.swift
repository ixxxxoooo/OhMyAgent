// @author ixxxxoooo
// 应用内平滑滚轮(思路同 Mos,但只作用于本应用窗口,不需要「辅助功能」权限):
// 本地事件监视器截获鼠标滚轮的离散事件 → 累计成「待滚动位移」→ 显示器刷新节拍里按指数衰减逐帧合成连续滚动事件,
// 直接送到原窗口(`NSWindow.sendEvent`),SwiftUI `ScrollView` 与 `NSScrollView` 都当作触控板滚动处理。
// 触控板、带阶段的精确滚动、带修饰键(缩放等)的滚动一律放行,不做任何改动。

import AppKit
import ChatKit
import QuartzCore

/// 平滑滚轮引擎(单例,主线程)。开关与档位来自偏好 `ClientPrefs.Key.smoothWheel*`,随时生效。
@MainActor
final class SmoothWheel: NSObject {
    static let shared = SmoothWheel()

    /// 合成事件的标记值,避免被自己再次处理
    private static let marker: Int64 = 0x4F4D_5357
    /// 单帧最大时间步长(秒):掉帧或休眠后恢复时不一次滚太多
    private static let maxFrameTime: Double = 1.0 / 20

    private var monitors: [Any] = []
    private var model = SmoothWheelModel()
    private var template: CGEvent?
    private weak var window: NSWindow?
    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0

    /// 是否开启(读偏好,默认关闭)。
    private var isEnabled: Bool { UserDefaults.standard.bool(forKey: ClientPrefs.Key.smoothWheel) }

    /// 当前档位。
    private var level: SmoothWheelLevel {
        SmoothWheelLevel.resolve(UserDefaults.standard.string(forKey: ClientPrefs.Key.smoothWheelLevel) ?? "")
    }

    /// 安装事件监视器(幂等);是否真正平滑由偏好决定。
    func start() {
        guard monitors.isEmpty else { return }
        if let wheel = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] event in
            guard let self else { return event }
            let consumed = MainActor.assumeIsolated { self.handle(event) }
            return consumed ? nil : event
        }) { monitors.append(wheel) }
        // 按下鼠标即停止惯性(与系统一致)
        if let click = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] event in
            MainActor.assumeIsolated { self?.cancel() }
            return event
        }) { monitors.append(click) }
    }

    /// 处理一次滚轮事件。
    /// - Parameter event: 原始事件
    /// - Returns: 是否已接管(接管后原事件被吞掉)
    private func handle(_ event: NSEvent) -> Bool {
        guard isEnabled, Self.isDiscreteWheel(event),
              let cg = event.cgEvent, cg.getIntegerValueField(.eventSourceUserData) != Self.marker,
              let target = event.window, let screen = target.screen else {
            if !isEnabled { cancel() }
            return false
        }
        template = cg.copy()
        window = target
        let line = Self.lineDelta(event.scrollingDeltaY)
        let columns = Self.lineDelta(event.scrollingDeltaX)
        model.add(dx: columns * SmoothWheelModel.pixelsPerLine, dy: line * SmoothWheelModel.pixelsPerLine)
        startLink(on: screen)
        return true
    }

    /// 是否为鼠标滚轮的离散事件:无精确位移、无阶段、无惯性阶段、无修饰键。
    /// - Parameter event: 滚轮事件
    /// - Returns: 是否应当平滑
    static func isDiscreteWheel(_ event: NSEvent) -> Bool {
        !event.hasPreciseScrollingDeltas && event.phase.isEmpty && event.momentumPhase.isEmpty
            && event.modifierFlags.intersection([.command, .control, .option]).isEmpty
    }

    /// 离散滚轮的位移按「行」计:小于 1 行的补足到 1 行(同 Mos 的最小步长),0 保持 0。
    /// - Parameter value: 事件位移
    /// - Returns: 行数
    static func lineDelta(_ value: CGFloat) -> Double {
        guard value != 0 else { return 0 }
        return abs(value) < 1 ? (value > 0 ? 1 : -1) : Double(value)
    }

    private func startLink(on screen: NSScreen) {
        guard link == nil else { return }
        let newLink = screen.displayLink(target: self, selector: #selector(tick(_:)))
        lastTimestamp = 0
        newLink.add(to: .main, forMode: .common)
        link = newLink
    }

    /// 每个刷新节拍:推进模型并合成一个滚动事件。
    @objc private func tick(_ displayLink: CADisplayLink) {
        let now = displayLink.targetTimestamp
        let dt = lastTimestamp == 0 ? 1.0 / 60 : min(now - lastTimestamp, Self.maxFrameTime)
        lastTimestamp = now
        let step = model.advance(dt: dt, tau: level.tau)
        if step.x != 0 || step.y != 0 { post(dx: step.x, dy: step.y) }
        if !model.isActive { finish() }
    }

    /// 结束一轮:停止刷新。
    private func finish() {
        stopLink()
    }

    /// 立刻取消(点击、关闭功能):清空剩余位移。
    private func cancel() {
        guard link != nil || model.isActive else { return }
        model.reset()
        finish()
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
    }

    /// 合成并投递一个连续滚动事件。
    /// - Parameters:
    ///   - dx: 横向像素
    ///   - dy: 纵向像素
    private func post(dx: Int, dy: Int) {
        guard let window, let cg = template?.copy() else { stopLink(); return }
        // 以原事件拷贝为底(保留窗口归属),把位移写进连续滚动用的各个字段
        cg.setIntegerValueField(.eventSourceUserData, value: Self.marker)
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        cg.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: Int64(dy))
        cg.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: Int64(dx))
        cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(dy))
        cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(dx))
        cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: Double(dy))
        cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: Double(dx))
        // 不带滚动阶段:带阶段的事件会触发 NSScrollView 的弹性过冲,边缘会越界回弹;无阶段则与普通滚轮一样在顶/底停住
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: 0)
        cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 0)
        guard let synthetic = NSEvent(cgEvent: cg) else { return }
        window.sendEvent(synthetic)
    }
}
