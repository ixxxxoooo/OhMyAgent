// @author ixxxxoooo
// 停靠在底部面板/工具栏里的会话:标签、图标与落点处理(把侧栏会话或编辑区会话标签拖到面板标签条上)。

import DesignSystem
import IconKit
import SwiftUI
import UniformTypeIdentifiers
import WorkbenchKit

/// 处理拖到面板标签条上的载荷:侧栏会话行或编辑区会话标签才生效。
/// - Parameters:
///   - payloads: 拖拽载荷文本
///   - host: 目标面板
///   - workbench: 工作台模型
/// - Returns: 是否接收
@MainActor
func dropChat(_ payloads: [String], host: PanelChatHost, in workbench: WorkbenchModel) -> Bool {
    guard let text = payloads.first,
          text.hasPrefix(DockDrag.sessionPrefix) || text.hasPrefix(DockDrag.prefix),
          let tabID = DockDrag.resolveTab(text, in: workbench) else { return false }
    var ok = false
    omWithAnimation { ok = workbench.dockChat(tab: tabID, to: host) }
    return ok
}

/// 底部面板标签条里的会话标签:点击切换,右键移回编辑区/关闭。
struct DockedChatTab: View {
    let workbench: WorkbenchModel
    let chat: PanelChat
    /// 是否为工具栏图标样式(只显示图标)
    var iconOnly = false

    var body: some View {
        let selected = workbench.activeChat(in: chat.host) == chat
        Button { workbench.select(chat) } label: {
            if iconOnly {
                Image.om("message-square", size: 14).frame(width: 28, height: 24).contentShape(Rectangle())
            } else {
                HStack(spacing: 4) {
                    Image.om("message-square", size: 12)
                    Text(title).lineLimit(1).frame(maxWidth: 140)
                }
            }
        }
        .omTooltip(title)
        .accessibilityLabel(title)
        .buttonStyle(.plain)
        .font(OMFonts.small.weight(selected ? .medium : .regular))
        .foregroundStyle(selected ? OMColors.primaryText : OMColors.secondaryText)
        .padding(.horizontal, iconOnly ? 0 : 8).padding(.vertical, iconOnly ? 0 : 3)
        .background(selected ? OMColors.selectedFill : .clear, in: iconOnly ? AnyShape(RoundedRectangle(cornerRadius: OMRadius.tag)) : AnyShape(OMPillShape()))
        .omContextMenu {
            OMMenuItem("移到编辑区", icon: "panel-top") { omWithAnimation { workbench.undockChat(chat) } }
            OMMenuItem("关闭会话", icon: "x") { omWithAnimation { workbench.closeDocked(chat) } }
        }
    }

    private var title: String {
        let model = workbench.conversations[ConversationKey(projectID: chat.projectID, slot: chat.slot)]
        if let t = model?.sessionTitle, !t.isEmpty { return t }
        return String(localized: "新对话")
    }
}
