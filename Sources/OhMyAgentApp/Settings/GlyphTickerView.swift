// @author ixxxxoooo
// 等待动画字符预览(外观页「等待文案样式」用):AppKit 文本控件 + 自带定时器逐帧换字符。
// 不用 SwiftUI `TimelineView`:后者每个刻度都会让整个视图图「时间变了」标脏并传播,
// 外观页视图很多,0.15 秒一刻时停在该页主线程约 40% 忙于更新;这里换字符只改一个 NSTextField。

import AppKit
import ChatKit
import DesignSystem
import SwiftUI

/// 动画字符预览。
struct GlyphTicker: NSViewRepresentable {
    /// 动画风格
    let style: WorkingVerbStyle
    /// 字符颜色
    let color: Color

    /// - Returns: 字符控件
    func makeNSView(context: Context) -> GlyphTickerField {
        let field = GlyphTickerField(labelWithString: "")
        field.alignment = .center
        field.font = NSFont.systemFont(ofSize: 13 * OMScale.ui, weight: .medium)
        field.setAccessibilityElement(false)
        return field
    }

    /// 同步风格与颜色(主题或选中变化时由父视图触发)。
    func updateNSView(_ field: GlyphTickerField, context: Context) {
        field.style = style
        field.textColor = NSColor(color)
        field.font = NSFont.systemFont(ofSize: 13 * OMScale.ui, weight: .medium)
    }

    /// 定时器只在控件位于窗口中时运行。
    static func dismantleNSView(_ field: GlyphTickerField, coordinator: ()) {
        field.stop()
    }
}

/// 逐帧换字符的文本控件:进入窗口启动定时器,离开窗口停止。
final class GlyphTickerField: NSTextField {
    /// 帧间隔(秒),与会话里的等待动画一致
    private static let interval = 0.15
    private var timer: Timer?

    /// 当前动画风格,变化时立即刷新字符
    var style: WorkingVerbStyle = .current() {
        didSet { if oldValue != style { render() } }
    }

    /// 尺寸由外层固定(18×18):换字符时不让固有尺寸失效,否则每帧都会触发外层 SwiftUI 宿主重新布局
    override var intrinsicContentSize: NSSize { NSSize(width: 18, height: 18) }

    override func invalidateIntrinsicContentSize() {}

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stop() } else { start() }
    }

    /// 启动定时器(已在运行则忽略)。
    func start() {
        render()
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.render() }
        }
        timer.tolerance = 0.02
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// 停止定时器。
    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// 按当前时刻取帧:各行用同一时间基准,动画步调一致。
    private func render() {
        let tick = Int(Date().timeIntervalSinceReferenceDate / Self.interval)
        let glyph = WorkingStatus.glyph(tick: tick, style: style)
        if stringValue != glyph { stringValue = glyph }
    }
}
