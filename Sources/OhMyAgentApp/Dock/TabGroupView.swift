// @author ygw
// 标签组:标签栏 + 内容区。支持标签拖拽(重排/跨组/拖到边缘新建分屏)、五区落点蒙层、右键菜单与溢出菜单。

import ChatKit
import DesignSystem
import IconKit
import SwiftUI
import UniformTypeIdentifiers
import WorkbenchKit

/// 应用内标签拖拽状态:拖拽开始时记录,落下时与剪贴板中的载荷核对后才生效。
@MainActor
final class DockDrag {
    static let shared = DockDrag()
    var tabID: UUID?
    nonisolated static let prefix = "oma-tab:"

    /// 由拖拽载荷字符串解析标签 ID。
    nonisolated static func parse(_ text: String) -> UUID? {
        guard text.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(text.dropFirst(prefix.count)))
    }
}

extension WorkbenchModel {
    /// 标签展示标题:会话标签优先使用会话标题,其余使用标签自带标题。
    @MainActor
    func displayTitle(_ tab: WorkbenchTab) -> String {
        switch tab.kind {
        case .chat(let id):
            return sessions[id]?.sessionTitle ?? projects.first { $0.id == id }?.name ?? tab.title
        case .subagent(let project, let toolCallID):
            return sessions[project]?.timeline.toolEntry(id: toolCallID)?.tool?.title ?? tab.title
        default:
            return tab.title
        }
    }
}

/// 标签图标(Lucide 名)。
func tabIcon(_ kind: TabKind) -> String {
    switch kind {
    case .chat: return "message-square"
    case .subagent: return "bot"
    case .file: return "file-code"
    case .diff, .changes: return "file-diff"
    case .terminal: return "square-terminal"
    case .preview: return "eye"
    case .history: return "git-graph"
    case .blame: return "user"
    }
}

/// 标签组视图。
struct TabGroupView: View {
    let workbench: WorkbenchModel
    let group: TabGroup
    @State private var zone: DockDropZone?

    private var isFocused: Bool { workbench.dock.focusedGroupID == group.id }

    var body: some View {
        VStack(spacing: 0) {
            TabBarView(workbench: workbench, group: group, isFocused: isFocused)
            Divider()
            GeometryReader { proxy in
                content
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
                    .overlay { DropOverlay(zone: zone).allowsHitTesting(false) }
                    .onDrop(of: [.plainText], delegate: GroupDropDelegate(workbench: workbench, groupID: group.id, size: proxy.size, zone: $zone))
            }
        }
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded {
            workbench.dock.focus(group: group.id)
            workbench.syncSelectionFromDock()
        })
    }

    @ViewBuilder
    private var content: some View {
        if let tab = group.active {
            TabContentView(workbench: workbench, tab: tab)
                .id(tab.id)
        } else {
            WelcomeView(workbench: workbench)
        }
    }
}

/// 落点蒙层:按落点高亮目标区域(中心为整块,边缘为半幅)。
private struct DropOverlay: View {
    let zone: DockDropZone?

    var body: some View {
        GeometryReader { proxy in
            if let zone {
                let w = proxy.size.width, h = proxy.size.height
                let rect: CGRect = switch zone {
                case .center: CGRect(x: 0, y: 0, width: w, height: h)
                case .left: CGRect(x: 0, y: 0, width: w / 2, height: h)
                case .right: CGRect(x: w / 2, y: 0, width: w / 2, height: h)
                case .top: CGRect(x: 0, y: 0, width: w, height: h / 2)
                case .bottom: CGRect(x: 0, y: h / 2, width: w, height: h / 2)
                }
                RoundedRectangle(cornerRadius: 6)
                    .fill(OMColors.accent.opacity(0.18))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(OMColors.accent.opacity(0.7), lineWidth: 1.5))
                    .frame(width: rect.width - 8, height: rect.height - 8)
                    .position(x: rect.midX, y: rect.midY)
                    .transition(.opacity)
            }
        }
    }
}

/// 内容区落点代理:实时计算落点并在放下时分屏/并入。
struct GroupDropDelegate: DropDelegate {
    let workbench: WorkbenchModel
    let groupID: UUID
    let size: CGSize
    @Binding var zone: DockDropZone?

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.plainText]) && DockDrag.shared.tabID != nil
    }

    func dropEntered(info: DropInfo) { zone = DockDropZone.zone(at: info.location, in: size) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        zone = DockDropZone.zone(at: info.location, in: size)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) { zone = nil }

    func performDrop(info: DropInfo) -> Bool {
        let target = zone ?? DockDropZone.zone(at: info.location, in: size)
        zone = nil
        guard let provider = info.itemProviders(for: [.plainText]).first else { return false }
        let model = workbench, group = groupID
        _ = provider.loadObject(ofClass: String.self) { text, _ in
            guard let text, let id = DockDrag.parse(text) else { return }
            Task { @MainActor in
                model.dock.drop(id, onGroup: group, zone: target)
                model.syncSelectionFromDock()
                DockDrag.shared.tabID = nil
            }
        }
        return true
    }
}

/// 标签栏落点代理:放到某个标签上插入其位置,放到空白处追加到末尾。
struct TabStripDropDelegate: DropDelegate {
    let workbench: WorkbenchModel
    let groupID: UUID
    /// 目标下标;nil 表示追加
    let index: Int?

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.plainText]) && DockDrag.shared.tabID != nil
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [.plainText]).first else { return false }
        let model = workbench, group = groupID, at = index
        _ = provider.loadObject(ofClass: String.self) { text, _ in
            guard let text, let id = DockDrag.parse(text) else { return }
            Task { @MainActor in
                model.dock.move(id, toGroup: group, at: at)
                model.syncSelectionFromDock()
                DockDrag.shared.tabID = nil
            }
        }
        return true
    }
}

/// 标签栏。
struct TabBarView: View {
    let workbench: WorkbenchModel
    let group: TabGroup
    let isFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(Array(group.tabs.enumerated()), id: \.element.id) { index, tab in
                        TabItemView(workbench: workbench, group: group, tab: tab, isActive: tab.id == group.activeID, isFocused: isFocused)
                            .onDrop(of: [.plainText], delegate: TabStripDropDelegate(workbench: workbench, groupID: group.id, index: index))
                    }
                    Color.clear
                        .frame(minWidth: 24, maxWidth: .infinity)
                        .contentShape(Rectangle())
                        .onDrop(of: [.plainText], delegate: TabStripDropDelegate(workbench: workbench, groupID: group.id, index: nil))
                }
            }
            if group.tabs.count > 1 {
                overflowMenu
            }
        }
        .frame(height: 32)
        .background(.bar)
    }

    private var overflowMenu: some View {
        Menu {
            ForEach(group.tabs) { tab in
                Button {
                    workbench.activateTab(tab.id)
                } label: {
                    Label(workbench.displayTitle(tab), om: tab.id == group.activeID ? "check" : tabIcon(tab.kind))
                }
            }
        } label: {
            Image.om("chevrons-up-down", size: 12).frame(width: 26, height: 26)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .foregroundStyle(OMColors.secondaryText)
        .help("所有标签")
        .accessibilityLabel("所有标签")
        .padding(.trailing, 4)
    }
}

/// 单个标签。
struct TabItemView: View {
    let workbench: WorkbenchModel
    let group: TabGroup
    let tab: WorkbenchTab
    let isActive: Bool
    let isFocused: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image.om(tabIcon(tab.kind), size: 12)
                .foregroundStyle(isActive ? OMColors.accent : OMColors.tertiaryText)
            Text(workbench.displayTitle(tab))
                .font(OMFonts.small)
                .italic(tab.isPreview)
                .lineLimit(1)
                .frame(maxWidth: 160)
                .foregroundStyle(isActive ? Color.primary : OMColors.secondaryText)
            trailing
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(isActive ? OMColors.surface : (hovering ? Color.primary.opacity(0.05) : Color.clear))
        .overlay(alignment: .bottom) {
            if isActive { Rectangle().fill(isFocused ? OMColors.accent : OMColors.tertiaryText).frame(height: 2) }
        }
        .overlay(alignment: .trailing) { Rectangle().fill(OMColors.hairline).frame(width: 0.5) }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) {
            if tab.isPreview { workbench.dock.keepOpen(tab.id) } else { workbench.dock.toggleMaximize(group: group.id) }
        }
        .onTapGesture { workbench.activateTab(tab.id) }
        .onDrag {
            DockDrag.shared.tabID = tab.id
            return NSItemProvider(object: (DockDrag.prefix + tab.id.uuidString) as NSString)
        }
        .contextMenu { menu }
        .help(helpText)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: Text("关闭标签")) { AppActions.shared.requestCloseTab(tab.id) }
    }

    /// 尾部:固定图标 / 未保存点 / 关闭按钮(悬停或激活时可见)。
    @ViewBuilder
    private var trailing: some View {
        ZStack {
            if tab.isPinned && !hovering {
                Image.om("pin", size: 10).foregroundStyle(OMColors.tertiaryText)
            } else if tab.isDirty && !hovering {
                Circle().fill(OMColors.secondaryText).frame(width: 7, height: 7)
            } else if hovering || isActive {
                Button { AppActions.shared.requestCloseTab(tab.id) } label: {
                    Image.om("xmark", size: 10, weight: .bold)
                }
                .buttonStyle(.plain)
                .foregroundStyle(OMColors.secondaryText)
                .accessibilityLabel("关闭标签")
            }
        }
        .frame(width: 14, height: 14)
    }

    private var helpText: String {
        switch tab.kind {
        case .file(let path), .diff(let path): return (path as NSString).abbreviatingWithTildeInPath
        default: return workbench.displayTitle(tab)
        }
    }

    @ViewBuilder
    private var menu: some View {
        Button("关闭") { AppActions.shared.requestCloseTab(tab.id) }
        Button("关闭其它") { workbench.dock.closeOthers(tab.id) }
            .disabled(group.tabs.count < 2)
        Divider()
        Button(tab.isPinned ? "取消固定" : "固定") { workbench.dock.togglePinned(tab.id) }
        Button("向右拆分") {
            workbench.dock.drop(tab.id, onGroup: group.id, zone: .right)
            workbench.syncSelectionFromDock()
        }
        .disabled(group.tabs.count < 2)
        Button(workbench.dock.maximizedGroupID == group.id ? "还原布局" : "最大化此组") { workbench.dock.toggleMaximize(group: group.id) }
        if case .file(let path) = tab.kind {
            Divider()
            Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
            Button("拷贝路径") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path, forType: .string)
            }
        }
    }
}
