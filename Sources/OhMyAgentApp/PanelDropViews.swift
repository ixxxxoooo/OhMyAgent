// @author ixxxxoooo
// 面板标签的拖拽(与编辑区标签同一套系统拖拽):终端/输出标签可拖到编辑区五区分屏、
// 底部栏、左右侧栏;编辑区里的终端/输出标签也能拖回这些位置。

import DesignSystem
import SwiftUI
import UniformTypeIdentifiers
import WorkbenchKit

extension View {
    /// 使视图成为面板标签的拖拽源(载荷为面板标识,落点与编辑区标签共用)。
    /// - Parameter item: 被拖拽的面板(终端/输出)
    func panelDragSource(_ item: PanelItem) -> some View {
        onDrag {
            DockDrag.shared.beginPanel(item)
            return NSItemProvider(object: item.payload as NSString)
        }
    }

    /// 使视图成为面板落点:放下终端/输出标签(含编辑区里的终端/输出标签)即把面板移到该区域。
    /// - Parameters:
    ///   - zone: 该视图所在的区域
    ///   - workbench: 工作台模型
    func panelDropZone(_ zone: PanelZone, workbench: WorkbenchModel) -> some View {
        modifier(PanelDropZoneModifier(zone: zone, workbench: workbench))
    }
}

/// 解析拖拽载荷对应的面板:面板载荷直接解析,编辑区终端/输出标签载荷按标签类型解析。
/// - Parameters:
///   - text: 拖拽载荷
///   - workbench: 工作台模型
/// - Returns: 终端或输出;其它载荷为 nil
@MainActor
func draggedPanelItem(_ text: String, in workbench: WorkbenchModel) -> PanelItem? {
    if let item = PanelItem.parse(payload: text) { return item == .terminal || item == .output ? item : nil }
    if let id = DockDrag.parse(text) { return workbench.panelItem(forTab: id) }
    return nil
}

/// 面板落点代理:悬停高亮,放下时移动面板。
private struct PanelDropDelegate: DropDelegate {
    let zone: PanelZone
    let workbench: WorkbenchModel
    @Binding var targeted: Bool

    /// 当前正在拖拽的是否为终端/输出(标签或面板)。
    @MainActor private var isPanelDrag: Bool {
        if let panel = DockDrag.shared.panel { return panel == .terminal || panel == .output }
        if let id = DockDrag.shared.tabID { return workbench.panelItem(forTab: id) != nil }
        return false
    }

    func validateDrop(info: DropInfo) -> Bool { MainActor.assumeIsolated { isPanelDrag } }
    func dropEntered(info: DropInfo) { targeted = true }
    func dropExited(info: DropInfo) { targeted = false }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        targeted = false
        guard let provider = info.itemProviders(for: [.plainText]).first else { return false }
        let model = workbench, target = zone
        _ = provider.loadObject(ofClass: String.self) { text, _ in
            guard let text else { return }
            Task { @MainActor in
                guard let item = draggedPanelItem(text, in: model) else { return }
                omWithAnimation { model.movePanel(item, to: target) }
                DockDrag.shared.tabID = nil
                DockDrag.shared.panel = nil
            }
        }
        return true
    }
}

/// 面板落点修饰器:高亮整块区域,提示「放到此处」。
private struct PanelDropZoneModifier: ViewModifier {
    let zone: PanelZone
    let workbench: WorkbenchModel
    @State private var targeted = false

    func body(content: Content) -> some View {
        content
            .onDrop(of: [.plainText], delegate: PanelDropDelegate(zone: zone, workbench: workbench, targeted: $targeted))
            .overlay {
                if targeted, DockDrag.shared.hasPayload {
                    RoundedRectangle(cornerRadius: OMRadius.tag)
                        .fill(OMColors.selectedFill)
                        .overlay(RoundedRectangle(cornerRadius: OMRadius.tag).strokeBorder(OMColors.accent.opacity(0.7), lineWidth: 1.5))
                        .padding(4)
                        .allowsHitTesting(false)
                }
            }
    }
}
