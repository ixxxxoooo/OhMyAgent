// @author ixxxxoooo
// IDE 窗口随尺寸自适应的布局计算(纯函数,无视图):窗口变窄时依次让出 Agent 面板、侧栏,变宽后自动恢复。
// 只影响「实际显示」,不改写模型里用户保存的可见性与宽度,所以窗口拉回去后布局原样回来。

import Foundation

/// 一次自适应计算的结果。
public struct IDEResponsiveLayout: Equatable, Sendable {
    /// 侧栏是否实际显示
    public let sidebarShown: Bool
    /// Agent 面板是否实际显示
    public let agentShown: Bool
    /// 侧栏实际宽度(不显示为 0)
    public let sidebarWidth: Double
    /// Agent 面板实际宽度(不显示为 0)
    public let agentWidth: Double

    /// 按窗口宽度推导实际布局。
    /// - Parameters:
    ///   - window: 工作区(活动栏起、状态栏上)的宽度
    ///   - sidebarVisible: 用户是否打开了侧栏
    ///   - sidebarWidth: 用户保存的侧栏宽度
    ///   - agentVisible: 用户是否打开了 Agent 面板
    ///   - agentWidth: 用户保存的 Agent 面板宽度
    /// - Returns: 实际显示状态与宽度;宽度非有限值时取默认值
    public static func resolve(window: Double, sidebarVisible: Bool, sidebarWidth: Double,
                               agentVisible: Bool, agentWidth: Double) -> IDEResponsiveLayout {
        let window = window.isFinite ? window : IDEMetrics.windowDefaultWidth
        var sidebarShown = sidebarVisible
        var agentShown = agentVisible
        func needed() -> Double {
            IDEMetrics.activityBarWidth + IDEMetrics.editorMinWidth
                + (sidebarShown ? IDEMetrics.sidebarRange.lowerBound : 0)
                + (agentShown ? IDEMetrics.agentRange.lowerBound : 0)
        }
        // 放不下最小宽度时先收 Agent 面板(最宽),仍不够再收侧栏
        if agentShown, needed() > window { agentShown = false }
        if sidebarShown, needed() > window { sidebarShown = false }
        let storedSidebar = IDEMetrics.clamp(sidebarWidth, to: IDEMetrics.sidebarRange, fallback: IDEMetrics.sidebarDefault)
        let storedAgent = IDEMetrics.clamp(agentWidth, to: IDEMetrics.agentRange, fallback: IDEMetrics.agentDefault)
        let sidebar = sidebarShown
            ? min(storedSidebar, IDEMetrics.sidebarMax(window: window, agentWidth: agentShown ? storedAgent : 0)) : 0
        let agent = agentShown
            ? min(storedAgent, IDEMetrics.agentMax(window: window, sidebarWidth: sidebar)) : 0
        return IDEResponsiveLayout(sidebarShown: sidebarShown, agentShown: agentShown, sidebarWidth: sidebar, agentWidth: agent)
    }
}
