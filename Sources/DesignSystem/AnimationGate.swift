// @author ixxxxoooo
// 循环动画门控:只有「标签可见 + 应用可见 + 未减弱动态」时才允许持续动画(流光、呼吸点、转圈),
// 避免后台标签、被遮挡/最小化的窗口白白消耗资源。循环动画本体见 LoopLayers.swift(Core Animation,不占主线程)。

import AppKit
import Observation
import SwiftUI

/// 循环动画是否应当运行的纯函数(便于单测)。
public enum OMAnimationGate {
    /// - Parameters:
    ///   - tabActive: 所在标签内容是否可见(`tabIsActive`)
    ///   - appVisible: 应用窗口是否可见(未被遮挡/最小化)
    ///   - reduceMotion: 是否减弱动态效果
    /// - Returns: 三者都满足才允许持续动画
    public static func shouldAnimate(tabActive: Bool, appVisible: Bool, reduceMotion: Bool) -> Bool {
        tabActive && appVisible && !reduceMotion
    }
}

/// 应用可见性(窗口被完全遮挡或最小化、应用隐藏时为 false);`@Observable` 供视图 body 自动订阅。
@MainActor
@Observable
public final class OMAppVisibility {
    public static let shared = OMAppVisibility()

    /// 应用是否可见。
    public private(set) var isVisible: Bool

    @ObservationIgnored private var observer: NSObjectProtocol?

    private init() {
        isVisible = NSApplication.shared.occlusionState.contains(.visible)
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeOcclusionStateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isVisible = NSApplication.shared.occlusionState.contains(.visible)
            }
        }
    }
}

/// 读取门控输入并产出「是否运行」的包装视图:body 里读取环境与 `OMAppVisibility`,变化时自动刷新子内容。
struct OMLoopGated<Content: View>: View {
    @ViewBuilder let content: (_ running: Bool) -> Content
    @Environment(\.tabIsActive) private var tabActive
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        content(OMAnimationGate.shouldAnimate(
            tabActive: tabActive, appVisible: OMAppVisibility.shared.isVisible,
            reduceMotion: reduceMotion || omShouldReduceMotion()
        ))
    }
}
