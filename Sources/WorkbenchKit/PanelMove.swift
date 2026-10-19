// @author ixxxxoooo
// 面板标签的跨区域移动:终端/输出在底部栏、侧栏、编辑区标签之间拖拽时的模型操作(无视图)。

import Foundation

@MainActor
public extension WorkbenchModel {
    /// 编辑区标签对应的可摆放面板(仅常驻终端标签与输出标签)。
    /// - Parameter id: 标签 ID
    /// - Returns: 面板条目;不是面板标签为 nil
    func panelItem(forTab id: UUID) -> PanelItem? {
        guard let tab = dock.allTabs.first(where: { $0.id == id }) else { return nil }
        switch tab.kind {
        case .terminal(let terminalID): return terminalID.hasPrefix("bottom:") ? .terminal : nil
        case .preview(let previewID): return previewID == Self.outputTabID ? .output : nil
        default: return nil
        }
    }

    /// 把终端/输出放进编辑区并返回其标签 ID(拖到编辑区分屏/并组时用,随后由调用方移动到落点)。
    /// - Parameter item: 面板条目(仅终端、输出)
    /// - Returns: 编辑区标签 ID;条目不支持或标签未能建立为 nil
    @discardableResult
    func openPanelTab(_ item: PanelItem) -> UUID? {
        guard item == .terminal || item == .output else { return nil }
        if layout.zone(of: item) != .editor { place(item, in: .editor) }
        if item == .terminal { showTerminal() } else { showOutput() }
        if item == .terminal { return (currentResidentTerminalTab ?? residentTerminalTabs.first)?.id }
        return outputTabs.first?.id
    }

    /// 把面板移到某区域并保证它可见(拖动标签到底部栏/侧栏时用;与仅换摆放的 `place` 不同,会显示该面板)。
    /// - Parameters:
    ///   - item: 面板条目
    ///   - zone: 目标区域
    /// - Returns: 是否生效
    @discardableResult
    func movePanel(_ item: PanelItem, to zone: PanelZone) -> Bool {
        guard place(item, in: zone) else { return false }
        switch item {
        case .terminal: showTerminal()
        case .output: showOutput()
        case .sidebar, .tools: break
        }
        return true
    }

    /// 终端/输出并入工具栏时:展开工具栏并选中该标签(未并入时无操作)。
    /// - Parameter item: 终端或输出
    func revealInTools(_ item: PanelItem) {
        let column: PanelColumn = item == .terminal ? .terminal : .output
        guard layout.isMergedIntoTools(column) else { return }
        layout.rightVisible = true
        layout.toolsPanel = item
        layout.activeToolsChat = nil
        layout.sidebarBrowserActive = false
    }
}
