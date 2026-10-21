// @author ixxxxoooo
// IDE 窗口外壳:标题栏 + 活动栏 + 侧栏 + 编辑区 + 底部面板 + Agent 面板 + 状态栏。
// 各区只读取自己关心的模型属性(Observation 按属性订阅),拖分隔条时只刷新被拖动的那一块;
// 颜色全部取自 `OMColors`,随主题实时刷新。

import DesignSystem
import IDEKit
import SwiftUI

/// IDE 窗口根视图。
struct IDEShellView: View {
    let workspace: IDEWorkspace
    private var model: IDEWindowModel { workspace.model }
    private let appearance = AppearanceModel.shared

    var body: some View {
        VStack(spacing: 0) {
            IDETitleBar(model: model)
            Rectangle().fill(OMColors.hairline).frame(height: 1)
            GeometryReader { geo in
                workArea(size: geo.size)
            }
            Rectangle().fill(OMColors.hairline).frame(height: 1)
            IDEStatusBar(model: model)
        }
        .background(OMColors.contentBackground)
        .ignoresSafeArea(.container, edges: .top)
        .tint(appearance.tint)
        .omScrollbarPolicy()
        .frame(minWidth: IDEMetrics.windowMinWidth, minHeight: IDEMetrics.windowMinHeight)
    }

    /// 活动栏 + 侧栏 + 中间(编辑区/面板)+ Agent 面板。宽度由量到的总宽直接算死,不交给 HStack 协商。
    private func workArea(size: CGSize) -> some View {
        let width = Double(size.width)
        let agentShown = model.agentPaneVisible
        let sidebarWidth = model.sidebarVisible
            ? min(model.sidebarWidth, IDEMetrics.sidebarMax(window: width, agentWidth: agentShown ? model.agentPaneWidth : 0)) : 0
        let agentWidth = agentShown
            ? min(model.agentPaneWidth, IDEMetrics.agentMax(window: width, sidebarWidth: sidebarWidth)) : 0
        return HStack(spacing: 0) {
            IDEActivityBar(model: model)
            if model.sidebarVisible {
                IDESidebarPane(workspace: workspace).frame(width: sidebarWidth)
                IDEResizer(model: model, kind: .sidebar, area: size)
            }
            VStack(spacing: 0) {
                if !(model.panelVisible && model.panelMaximized) {
                    IDEEditorArea(workspace: workspace)
                }
                if model.panelVisible {
                    if !model.panelMaximized { IDEResizer(model: model, kind: .panel, area: size) }
                    IDEBottomPanel(workspace: workspace)
                        .frame(height: model.panelMaximized ? nil : min(model.panelHeight, IDEMetrics.panelMax(window: Double(size.height) + IDEMetrics.titleBarHeight + IDEMetrics.statusBarHeight)))
                }
            }
            .frame(minWidth: IDEMetrics.editorMinWidth, maxWidth: .infinity)
            .clipped()
            if agentShown {
                IDEResizer(model: model, kind: .agent, area: size)
                IDEAgentPane(workspace: workspace).frame(width: agentWidth)
            }
        }
    }
}

/// 分隔条:侧栏(右缘)、底部面板(上缘)、Agent 面板(左缘)共用。
/// 拖动用「按下时的值 + 位移」换算并钳制;松手无需额外提交(模型本身带防抖落盘);双击恢复默认尺寸。
struct IDEResizer: View {
    /// 被拖动的区域
    enum Kind { case sidebar, panel, agent }

    let model: IDEWindowModel
    let kind: Kind
    /// 工作区(标题栏与状态栏之间)的尺寸,用于计算上限
    let area: CGSize
    @State private var base: Double?

    private var current: Double {
        switch kind {
        case .sidebar: model.sidebarWidth
        case .panel: model.panelHeight
        case .agent: model.agentPaneWidth
        }
    }

    var body: some View {
        OMSplitHandle(
            axis: kind == .panel ? .horizontal : .vertical,
            onBegan: { base = current },
            onChanged: { translation in
                let start = base ?? current
                if base == nil { base = start }
                apply(start: start, translation: Double(translation))
            },
            onEnded: { base = nil },
            onDoubleClick: { reset() }
        )
        .accessibilityLabel(label)
        .accessibilityAdjustableAction { direction in
            let step: Double = 20
            switch direction {
            case .increment: apply(start: current, translation: kind == .agent ? -step : step, inverted: kind == .panel)
            case .decrement: apply(start: current, translation: kind == .agent ? step : -step, inverted: kind == .panel)
            @unknown default: break
            }
        }
    }

    private var label: String {
        switch kind {
        case .sidebar: String(localized: "调整侧栏宽度")
        case .panel: String(localized: "调整面板高度")
        case .agent: String(localized: "调整 Agent 面板宽度")
        }
    }

    /// 按位移换算并写入模型:侧栏向右拖变宽;Agent 面板向左拖变宽;底部面板向上拖变高(位移向下为正)。
    private func apply(start: Double, translation: Double, inverted: Bool = false) {
        let width = Double(area.width)
        switch kind {
        case .sidebar:
            let upper = IDEMetrics.sidebarMax(window: width, agentWidth: model.agentPaneVisible ? model.agentPaneWidth : 0)
            model.sidebarWidth = IDEMetrics.clamp(start + translation, to: IDEMetrics.sidebarRange.lowerBound...upper, fallback: IDEMetrics.sidebarDefault)
        case .agent:
            let upper = IDEMetrics.agentMax(window: width, sidebarWidth: model.sidebarVisible ? model.sidebarWidth : 0)
            model.agentPaneWidth = IDEMetrics.clamp(start - translation, to: IDEMetrics.agentRange.lowerBound...upper, fallback: IDEMetrics.agentDefault)
        case .panel:
            let upper = IDEMetrics.panelMax(window: Double(area.height) + IDEMetrics.titleBarHeight + IDEMetrics.statusBarHeight)
            let delta = inverted ? translation : -translation
            model.panelHeight = IDEMetrics.clamp(start + delta, to: IDEMetrics.panelRange.lowerBound...upper, fallback: IDEMetrics.panelDefault)
        }
    }

    private func reset() {
        switch kind {
        case .sidebar: model.setSidebarWidth(IDEMetrics.sidebarDefault)
        case .panel: model.setPanelHeight(IDEMetrics.panelDefault)
        case .agent: model.setAgentPaneWidth(IDEMetrics.agentDefault)
        }
    }
}
