// @author ixxxxoooo
// IDE 性能 HUD:窗口右上角的小浮层,显示帧率、掉帧、最长帧、内存、CPU 与 IDE 窗口数。
// 仅在显示时才启动采样(CADisplayLink + 1 秒定时读资源),隐藏即停止,零常驻开销。
// 命令 `view.perfHUD`(命令面板 / 视图菜单)切换。

import AppKit
import DesignSystem
import IDEKit
import Observation
import OMLog
import SwiftUI

/// HUD 采样器:帧间隔来自 `CADisplayLink`,资源读数来自 `ResourceSampler`。
@MainActor
@Observable
final class IDEPerfHUDSampler: NSObject {
    /// 当前帧间隔统计
    private(set) var frames = IDEFrameStats()
    /// 本进程占用(MB)
    private(set) var footprintMB: Double = 0
    /// CPU 占用百分比(单核 100%)
    private(set) var cpuPercent: Double?
    /// 已打开的 IDE 窗口数
    private(set) var windowCount = 0

    @ObservationIgnored private var link: CADisplayLink?
    @ObservationIgnored private var lastTimestamp: CFTimeInterval = 0
    @ObservationIgnored private var resourceTask: Task<Void, Never>?
    /// 每累计这么多帧才刷新一次可观察属性,避免 HUD 自己造成每帧重绘
    @ObservationIgnored private var pendingFrames = 0
    @ObservationIgnored private var pending = IDEFrameStats()

    /// 开始采样(重复调用无副作用)。
    func start() {
        guard link == nil, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let link = screen.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        pending = IDEFrameStats(expectedMs: (link.targetTimestamp - link.timestamp) * 1000)
        refreshResources()
        resourceTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.refreshResources()
            }
        }
    }

    /// 停止采样并清空窗口。
    func stop() {
        link?.invalidate()
        link = nil
        resourceTask?.cancel()
        resourceTask = nil
        lastTimestamp = 0
        pending.reset()
        pendingFrames = 0
        frames.reset()
    }

    @objc private func tick(_ link: CADisplayLink) {
        if lastTimestamp > 0 { pending.record((link.timestamp - lastTimestamp) * 1000) }
        lastTimestamp = link.timestamp
        pendingFrames += 1
        if pendingFrames >= 30 {
            pendingFrames = 0
            frames = pending
        }
    }

    private func refreshResources() {
        let sample = ResourceSampler.shared.sample()
        footprintMB = sample?.footprintMB ?? footprintMB
        cpuPercent = sample?.cpuPercent
        windowCount = IDEWindowManager.shared.openCount
    }
}

/// HUD 视图:模型里 `perfHUDVisible` 为真时才挂载并采样。
struct IDEPerfHUD: View {
    let model: IDEWindowModel
    @State private var sampler = IDEPerfHUDSampler()

    var body: some View {
        Group {
            if model.perfHUDVisible {
                VStack(alignment: .leading, spacing: 2) {
                    row("帧率", String(format: "%.0f fps", sampler.frames.fps))
                    row("掉帧 / 最长", "\(sampler.frames.hitches) / " + String(format: "%.0f ms", sampler.frames.maxMs))
                    row("内存", String(format: "%.0f MB", sampler.footprintMB))
                    row("CPU", sampler.cpuPercent.map { String(format: "%.0f%%", $0) } ?? "—")
                    row("IDE 窗口", "\(sampler.windowCount)")
                }
                .padding(OMSpacing.sm)
                .background(OMColors.card, in: RoundedRectangle(cornerRadius: OMRadius.card))
                .overlay(RoundedRectangle(cornerRadius: OMRadius.card).stroke(OMColors.hairline, lineWidth: 1))
                .omCardShadow()
                .padding(OMSpacing.sm)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text("性能 HUD"))
                .allowsHitTesting(false)
                .onAppear { sampler.start() }
                .onDisappear { sampler.stop() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    }

    private func row(_ title: LocalizedStringKey, _ value: String) -> some View {
        HStack(spacing: OMSpacing.sm) {
            Text(title).font(OMFonts.caption).foregroundStyle(OMColors.secondaryText)
            Spacer(minLength: OMSpacing.md)
            Text(value).font(OMFonts.monoSmall).foregroundStyle(OMColors.primaryText)
        }
        .frame(minWidth: 150)
    }
}
