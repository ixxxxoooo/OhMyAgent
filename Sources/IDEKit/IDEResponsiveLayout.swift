// @author ixxxxoooo
// IDE 窗口随尺寸自适应的布局计算(纯函数,无视图):窗口变窄时依次让出侧栏、编辑区,最窄只剩 Agent 面板;变宽后自动恢复。
// 只影响「实际显示」,不改写模型里用户保存的可见性与宽度,所以窗口拉回去后布局原样回来。

import Foundation

/// 一次自适应计算的结果。
public struct IDEResponsiveLayout: Equatable, Sendable {
    /// 侧栏是否实际显示
    public let sidebarShown: Bool
    /// 编辑区(中间区域)是否实际显示;为 false 时只剩活动栏与撑满的 Agent 面板
    public let editorShown: Bool
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
        var editorShown = true
        let agentShown = agentVisible
        func needed() -> Double {
            IDEMetrics.activityBarWidth
                + (editorShown ? IDEMetrics.editorMinWidth : 0)
                + (sidebarShown ? IDEMetrics.sidebarRange.lowerBound : 0)
                + (agentShown ? IDEMetrics.agentRange.lowerBound : 0)
        }
        // 放不下最小宽度时先收侧栏;仍不够且 Agent 面板开着,再收编辑区,最后只剩 Agent 面板
        if sidebarShown, needed() > window { sidebarShown = false }
        if agentShown, needed() > window { editorShown = false }
        let storedSidebar = IDEMetrics.clamp(sidebarWidth, to: IDEMetrics.sidebarRange, fallback: IDEMetrics.sidebarDefault)
        let storedAgent = IDEMetrics.clamp(agentWidth, to: IDEMetrics.agentRange, fallback: IDEMetrics.agentDefault)
        let sidebar = sidebarShown
            ? min(storedSidebar, IDEMetrics.sidebarMax(window: window, agentWidth: agentShown ? storedAgent : 0)) : 0
        let agent = agentShown
            ? min(storedAgent, IDEMetrics.agentMax(window: window, sidebarWidth: sidebar)) : 0
        return IDEResponsiveLayout(sidebarShown: sidebarShown, editorShown: editorShown, agentShown: agentShown, sidebarWidth: sidebar, agentWidth: agent)
    }
}
