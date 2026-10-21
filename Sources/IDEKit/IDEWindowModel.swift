// @author ixxxxoooo
// IDE 窗口模型:每个 IDE 窗口一份,持有工作区根、侧栏/面板/Agent 面板的显隐与尺寸、编辑器停靠布局。
// 视图只读取自己关心的属性(Observation 按属性订阅),拖分隔条时只刷新被拖动的那一块。

import Foundation
import Observation
import WorkbenchKit

@MainActor
@Observable
public final class IDEWindowModel: Identifiable {
    public let id: UUID
    /// 工作区根目录(规范化路径);空窗口为 nil
    public var workspaceRoot: String? { didSet { if workspaceRoot != oldValue { changed() } } }
    public var sidebarView: IDESidebarView { didSet { if sidebarView != oldValue { changed() } } }
    public var sidebarVisible: Bool { didSet { if sidebarVisible != oldValue { changed() } } }
    public var sidebarWidth: Double { didSet { if sidebarWidth != oldValue { changed() } } }
    public var panelVisible: Bool { didSet { if panelVisible != oldValue { changed() } } }
    public var panelHeight: Double { didSet { if panelHeight != oldValue { changed() } } }
    /// 底部面板当前标签页
    public var panelTab: IDEPanelTab { didSet { if panelTab != oldValue { changed() } } }
    /// 本窗口的终端标识(进程随应用退出结束,不持久化)
    public private(set) var terminalIDs: [String] = []
    /// 当前显示的终端
    public var activeTerminalID: String?
    /// 问题存储(语言服务器诊断汇总)
    @ObservationIgnored public let problems = ProblemsStore()
    /// 底部面板最大化(仅界面状态,不持久化)
    public var panelMaximized = false
    public var agentPaneVisible: Bool { didSet { if agentPaneVisible != oldValue { changed() } } }
    public var agentPaneWidth: Double { didSet { if agentPaneWidth != oldValue { changed() } } }
    /// 窗口外框(由窗口控制器在移动/缩放后回写)
    public var frame: IDEWindowFrame? { didSet { if frame != oldValue { changed() } } }
    /// 编辑器停靠布局
    public var editor: DockLayout { didSet { if editor != oldValue { changed() } } }
    /// 最近一次激活时间
    public private(set) var lastActivated: Date

    /// 变更回调(由注册表接入,用来防抖落盘)。
    @ObservationIgnored public var onChange: (() -> Void)?

    /// 由快照创建。
    /// - Parameter snapshot: 持久化快照(会先钳制尺寸)
    public init(snapshot: IDEWindowSnapshot) {
        var snap = snapshot
        snap.clamp()
        id = snap.id
        workspaceRoot = snap.workspaceRoot
        sidebarView = snap.sidebarView
        sidebarVisible = snap.sidebarVisible
        sidebarWidth = snap.sidebarWidth
        panelVisible = snap.panelVisible
        panelHeight = snap.panelHeight
        panelTab = snap.panelTab ?? .terminal
        agentPaneVisible = snap.agentPaneVisible
        agentPaneWidth = snap.agentPaneWidth
        frame = snap.frame
        editor = snap.editor
        lastActivated = snap.lastActivated
    }

    /// 取当前状态的快照(值类型,可跨并发边界)。
    public func snapshot() -> IDEWindowSnapshot {
        var snap = IDEWindowSnapshot(id: id, workspaceRoot: workspaceRoot)
        snap.sidebarView = sidebarView
        snap.sidebarVisible = sidebarVisible
        snap.sidebarWidth = sidebarWidth
        snap.panelVisible = panelVisible
        snap.panelHeight = panelHeight
        snap.panelTab = panelTab
        snap.agentPaneVisible = agentPaneVisible
        snap.agentPaneWidth = agentPaneWidth
        snap.frame = frame
        snap.editor = editor
        snap.lastActivated = lastActivated
        return snap
    }

    /// 标记为刚刚激活。
    /// - Parameter date: 激活时间(测试可注入)
    public func markActivated(at date: Date = Date()) {
        lastActivated = date
        changed()
    }

    /// 显示名:根目录最后一级;空窗口为「未打开文件夹」由界面层决定,这里返回 nil。
    public var workspaceName: String? {
        workspaceRoot.map { ($0 as NSString).lastPathComponent }
    }

    // MARK: 面板操作

    /// 点击活动栏图标:选中另一个视图时切换并展开;再次点击当前视图则收起侧栏。
    /// - Parameter view: 点击的视图
    public func selectSidebar(_ view: IDESidebarView) {
        if sidebarVisible, sidebarView == view {
            sidebarVisible = false
        } else {
            sidebarView = view
            sidebarVisible = true
        }
    }

    /// 切换侧栏显隐。
    public func toggleSidebar() { sidebarVisible.toggle() }

    /// 切换底部面板显隐;收起时同时取消最大化。
    public func togglePanel() {
        panelVisible.toggle()
        if !panelVisible { panelMaximized = false }
    }

    /// 显示底部面板并切到某标签页。
    /// - Parameter tab: 标签页
    public func showPanel(_ tab: IDEPanelTab) {
        panelTab = tab
        panelVisible = true
    }

    /// 登记一个新终端并激活。
    /// - Parameter id: 终端标识(已存在则只激活)
    public func addTerminal(_ id: String) {
        guard !id.isEmpty else { return }
        if !terminalIDs.contains(id) { terminalIDs.append(id) }
        activeTerminalID = id
    }

    /// 移除终端;若它是当前终端,激活相邻的一个。
    /// - Parameter id: 终端标识
    public func removeTerminal(_ id: String) {
        guard let index = terminalIDs.firstIndex(of: id) else { return }
        terminalIDs.remove(at: index)
        if activeTerminalID == id { activeTerminalID = terminalIDs.indices.contains(index) ? terminalIDs[index] : terminalIDs.last }
    }

    /// 切换 Agent 面板显隐。
    public func toggleAgentPane() { agentPaneVisible.toggle() }

    /// 设置侧栏宽度(钳制到范围)。
    /// - Parameter value: 期望宽度
    public func setSidebarWidth(_ value: Double) {
        sidebarWidth = IDEMetrics.clamp(value, to: IDEMetrics.sidebarRange, fallback: IDEMetrics.sidebarDefault)
    }

    /// 设置底部面板高度(钳制到范围)。
    /// - Parameter value: 期望高度
    public func setPanelHeight(_ value: Double) {
        panelHeight = IDEMetrics.clamp(value, to: IDEMetrics.panelRange, fallback: IDEMetrics.panelDefault)
    }

    /// 设置 Agent 面板宽度(钳制到范围)。
    /// - Parameter value: 期望宽度
    public func setAgentPaneWidth(_ value: Double) {
        agentPaneWidth = IDEMetrics.clamp(value, to: IDEMetrics.agentRange, fallback: IDEMetrics.agentDefault)
    }

    private func changed() { onChange?() }
}
