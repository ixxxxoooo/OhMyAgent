// @author ygw
// 材质策略:根据系统“减少透明度”、低电量模式与用户设置,决定使用玻璃还是不透明材质。

import AppKit
import Observation
import SwiftUI

/// 用户的透明度偏好。
public enum TransparencyPreference: String, Sendable, CaseIterable {
    /// 跟随系统(默认)
    case system
    /// 始终使用不透明材质
    case alwaysOpaque
}

/// 全局材质策略。切换只改变一个布尔值,不会重建视图树。
@MainActor
@Observable
public final class MaterialPolicy {
    public static let shared = MaterialPolicy()

    /// 当前是否应使用 Liquid Glass。
    public private(set) var useGlass: Bool = true
    /// 用户偏好。
    public var preference: TransparencyPreference = .system { didSet { recompute() } }
    /// 低电量模式下是否自动回退。
    public var fallbackOnLowPower: Bool = true { didSet { recompute() } }

    private var observers: [NSObjectProtocol] = []

    private init() {
        recompute()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.recompute() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.recompute() }
        })
    }

    /// 重新计算是否使用玻璃。
    public func recompute() {
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        let value = !(reduceTransparency || preference == .alwaysOpaque || (fallbackOnLowPower && lowPower))
        if value != useGlass { useGlass = value }
    }
}
