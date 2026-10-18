// @author ixxxxoooo
// 终端列表:终端面板右侧的「N 个终端」列表(Cursor / VS Code 风格),≥2 个终端时出现。
// 点击切换、双击行内重命名、右键菜单、悬停关闭、拖动排序;颜色与字号只取设计令牌。

import ChatKit
import DesignSystem
import IconKit
import SwiftUI
import WorkbenchKit

/// 终端拖动排序的载荷:带前缀,避免与标签、面板等其它 String 拖放混淆。
enum TerminalDragPayload {
    private static let prefix = "oma-terminal:"

    /// 生成载荷。
    /// - Parameter id: 终端实例 id
    static func make(_ id: String) -> String { prefix + id }

    /// 解析载荷。
    /// - Parameter payload: 拖放内容
    /// - Returns: 终端实例 id;不是终端载荷或 id 为空时返回 nil
    static func parse(_ payload: String) -> String? {
        guard payload.hasPrefix(prefix) else { return nil }
        let id = String(payload.dropFirst(prefix.count))
        return id.isEmpty ? nil : id
    }
}

/// 终端列表视图(无状态:数据与动作都由 `TerminalPanelView` 传入)。
struct TerminalListView: View {
    let state: TerminalPanelState
    let titleOf: (TerminalInstance) -> String
    let menu: (TerminalInstance) -> [MenuEntry]
    let onSelect: (String) -> Void
    let onClose: (String) -> Void
    let onRename: (String, String) -> Void
    let onMove: (String, String?) -> Void
    let onAdd: () -> Void
    let onCollapse: () -> Void

    /// 正在行内重命名的实例
    @State private var editingID: String?
    @State private var draft = ""
    @FocusState private var focusedID: String?
    /// 拖动经过的落点:实例 id 表示插到它之前,`endMarker` 表示插到末尾
    @State private var dropTarget: String?
    private static let endMarker = "\u{0}end"

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(state.instances) { row($0) }
                    Color.clear.frame(height: 24).contentShape(Rectangle())
                        .dropDestination(for: String.self) { payloads, _ in drop(payloads, before: nil) }
                            isTargeted: { dropTarget = $0 ? Self.endMarker : (dropTarget == Self.endMarker ? nil : dropTarget) }
                }
                .padding(.horizontal, 6).padding(.bottom, 6)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(OMColors.surface)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("终端列表")
    }

    // MARK: 标题行

    private var header: some View {
        HStack(spacing: 2) {
            Text("\(state.instances.count) 个终端")
                .font(OMFonts.small)
                .foregroundStyle(OMColors.secondaryText)
                .lineLimit(1)
            Spacer(minLength: 0)
            Button(action: onAdd) { Image.om("plus", size: 12) }
                .buttonStyle(.omIcon)
                .disabled(!state.canAdd)
                .omTooltip("新建终端")
                .accessibilityLabel("新建终端")
            Button(action: onCollapse) { Image.om("panel-right-close", size: 12) }
                .buttonStyle(.omIcon)
                .omTooltip("收起终端列表")
                .accessibilityLabel("收起终端列表")
        }
        .padding(.leading, 12).padding(.trailing, 6)
        .frame(height: 28)
    }

    // MARK: 行

    private func row(_ instance: TerminalInstance) -> some View {
        TerminalListRow(
            title: titleOf(instance),
            isActive: instance.id == state.activeID,
            isExited: !(TerminalStore.shared.controllers[instance.id]?.isRunning ?? true),
            isEditing: editingID == instance.id,
            draft: $draft,
            focused: $focusedID,
            id: instance.id,
            onSelect: { onSelect(instance.id) },
            onBeginEdit: { beginEdit(instance) },
            onCommit: { commitEdit(instance) },
            onCancel: { editingID = nil },
            onClose: { onClose(instance.id) }
        )
        .overlay(alignment: .top) {
            if dropTarget == instance.id { Rectangle().fill(OMColors.accent).frame(height: 2) }
        }
        .omContextMenu { menu(instance) }
        .draggable(TerminalDragPayload.make(instance.id))
        .dropDestination(for: String.self) { payloads, _ in drop(payloads, before: instance.id) }
            isTargeted: { dropTarget = $0 ? instance.id : (dropTarget == instance.id ? nil : dropTarget) }
    }

    private func beginEdit(_ instance: TerminalInstance) {
        draft = titleOf(instance)
        editingID = instance.id
        focusedID = instance.id
    }

    /// 提交行内重命名(空白恢复自动标题);失去焦点或回车都会走这里。
    private func commitEdit(_ instance: TerminalInstance) {
        guard editingID == instance.id else { return }
        editingID = nil
        // 名称没变就不写成自定义名称,避免把 shell 上报的标题固化下来
        guard draft != titleOf(instance) else { return }
        onRename(instance.id, draft)
    }

    private func drop(_ payloads: [String], before target: String?) -> Bool {
        dropTarget = nil
        guard let id = payloads.compactMap(TerminalDragPayload.parse).first else { return false }
        omWithAnimation { onMove(id, target) }
        return true
    }
}

/// 列表中的一行:图标 + 名称(可行内编辑)+ 状态点 + 关闭按钮(悬停或激活时显示)。
private struct TerminalListRow: View {
    let title: String
    let isActive: Bool
    let isExited: Bool
    let isEditing: Bool
    @Binding var draft: String
    var focused: FocusState<String?>.Binding
    let id: String
    let onSelect: () -> Void
    let onBeginEdit: () -> Void
    let onCommit: () -> Void
    let onCancel: () -> Void
    let onClose: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image.om("square-terminal", size: 12)
            if isEditing {
                TextField("", text: $draft)
                    .textFieldStyle(.plain)
                    .font(OMFonts.small)
                    .focused(focused, equals: id)
                    .onSubmit(onCommit)
                    .onExitCommand(perform: onCancel)
                    .onChange(of: focused.wrappedValue) { _, now in if now != id { onCommit() } }
            } else {
                Text(verbatim: title).font(OMFonts.small).lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 0)
            if isExited { OMSessionDot(.idle, size: 6).omTooltip("进程已结束") }
            Button(action: onClose) {
                Image.om("x", size: 10).frame(width: 16, height: 16).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(hovering || isActive ? 1 : 0)
            .omTooltip("关闭终端")
            .accessibilityLabel("关闭终端")
        }
        .foregroundStyle(isActive ? OMColors.primaryText : OMColors.secondaryText)
        .padding(.leading, 8).padding(.trailing, 4)
        .frame(height: 26)
        .background(isActive ? OMColors.selectedFill : (hovering ? OMColors.hoverFill : .clear), in: OMPillShape())
        .contentShape(OMPillShape())
        .onTapGesture(count: 2, perform: onBeginEdit)
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
    }
}
