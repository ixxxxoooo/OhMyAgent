// @author ixxxxoooo
// 标签组:标签栏 + 内容区。支持标签拖拽(重排/跨组/拖到边缘新建分屏)、五区落点蒙层、右键菜单与溢出菜单。

import ChatKit
import DesignSystem
import IconKit
import OMLog
import SwiftUI
import UniformTypeIdentifiers
import WorkbenchKit

/// 应用内标签拖拽状态:拖拽开始时记录,落下时与剪贴板中的载荷核对后才生效。
@MainActor
@Observable
final class DockDrag {
    static let shared = DockDrag()
    /// 正在被拖拽的标签(源标签据此隐藏,避免与拖影重叠成「重影」)
    var tabID: UUID?
    @ObservationIgnored private var watcher: Task<Void, Never>?

    /// 拖拽开始:记录标签,并监视鼠标左键抬起。SwiftUI 没有「拖拽结束」回调,
    /// 拖到无效区域松手时必须靠这里复位,否则源标签会一直隐藏。
    func begin(_ id: UUID) {
        tabID = id
        watcher?.cancel()
        watcher = Task { @MainActor [weak self] in
            // 先等拖拽真正开始(按键仍按下)
            while !Task.isCancelled, NSEvent.pressedMouseButtons & 1 != 0 {
                try? await Task.sleep(for: .milliseconds(60))
            }
            // 给落点回调留出读取 tabID 的时间
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.tabID = nil
        }
    }
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
        case .chat:
            if let title = session(forTab: tab)?.sessionTitle, !title.isEmpty { return title }
            return tab.title
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
    case .terminal, .agentTerminal: return "square-terminal"
    case .preview(let id):
        if id == WorkbenchModel.automationTabID { return "workflow" }
        if id == WorkbenchModel.customizeTabID { return "sliders-horizontal" }
        if WorkbenchModel.canvasID(fromTab: id) != nil { return "chart-column" }
        if WorkbenchModel.browserID(fromTab: id) != nil { return "globe" }
        if WorkbenchModel.planPath(fromTab: id) != nil { return "list-todo" }
        return id == WorkbenchModel.outputTabID ? "file-text" : "eye"
    case .history: return "git-graph"
    case .blame: return "user"
    }
}

/// 停靠节点贴着窗口哪几条边(决定标签栏要不要给左上浮层按钮/右上右栏开关让位)。
struct DockEdges: Equatable {
    var left = true
    var top = true
    var right = true

    /// 分屏中第 `index` 个子节点(共 `count` 个)继承的贴边关系。
    func child(at index: Int, of count: Int, horizontal: Bool) -> DockEdges {
        if horizontal {
            return DockEdges(left: left && index == 0, top: top, right: right && index == count - 1)
        }
        return DockEdges(left: left, top: top && index == 0, right: right)
    }
}

/// 标签组视图。
struct TabGroupView: View {
    let workbench: WorkbenchModel
    let group: TabGroup
    /// 该组贴着停靠区的哪几条边
    var edges = DockEdges()
    @State private var zone: DockDropZone?
    /// 保活的标签(最近使用的若干个视图保持挂载,切换时不重建)
    @State private var keepAlive = TabKeepAlive()

    private var isFocused: Bool { workbench.dock.focusedGroupID == group.id }

    var body: some View {
        let _ = PanelToggleProbe.count("tabGroup")
        VStack(spacing: 0) {
            TabBarView(
                workbench: workbench, group: group, isFocused: isFocused,
                leadingInset: edges.top && edges.left && workbench.layout.visibleColumns(on: .left).isEmpty
                    ? TitlebarMetrics.leftClusterWidth(toggles: workbench.layout.toggleCount(on: .left)) : 0,
                trailingInset: edges.top && edges.right && workbench.layout.visibleColumns(on: .right).isEmpty
                    ? TitlebarMetrics.rightClusterWidth(toggles: workbench.layout.toggleCount(on: .right)) : 0
            )
            GeometryReader { proxy in
                content(size: proxy.size)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
                    .overlay { DropOverlay(zone: zone).allowsHitTesting(false) }
                    .onDrop(of: [.plainText, .fileURL], delegate: GroupDropDelegate(workbench: workbench, groupID: group.id, size: proxy.size, zone: $zone))
            }
        }
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded {
            workbench.dock.focus(group: group.id)
            workbench.syncSelectionFromDock()
        })
    }

    /// 内容区:当前标签 + 最近使用的标签都保持挂载,非激活的隐藏(隐藏会让 AppKit 视图让出键盘焦点),
    /// 因此切换标签不再重建编辑器、重新高亮或重新连接语言服务器。
    @ViewBuilder
    private func content(size: CGSize) -> some View {
        if group.active != nil {
            ZStack {
                ForEach(keepAlive.mounted(in: group.tabs, active: group.activeID)) { tab in
                    let isActive = tab.id == group.activeID
                    TabContentView(workbench: workbench, tab: tab)
                        // 隐藏的保活标签冻结在失活时的尺寸:窗口/侧栏宽度变化不再让每个隐藏会话重新排版,激活时才一次性恢复
                        .modifier(InactiveSizeFreeze(isActive: isActive, size: size))
                        .environment(\.tabIsActive, isActive)
                        .opacity(isActive ? 1 : 0)
                        .allowsHitTesting(isActive)
                        .accessibilityHidden(!isActive)
                }
            }
            .onChange(of: group.activeID, initial: true) {
                // 标签切换耗时:到下一个主循环(本轮布局/提交之后)为止
                let span = Log.perf.span("标签切换", warnMs: 50, ["tab": group.active?.title ?? "-"])
                DispatchQueue.main.async { span.end() }
                keepAlive.activate(group.activeID, in: group.tabs)
            }
            .onChange(of: group.tabs.map(\.id)) {
                keepAlive.activate(group.activeID, in: group.tabs)
            }
        } else {
            WelcomeView(workbench: workbench)
        }
    }
}

/// 冻结隐藏标签的布局尺寸。
///
/// 保活的标签只是 `opacity(0)`,仍参与布局;每次容器尺寸变化(开关侧栏、拖动分隔条、改窗口大小)
/// 所有隐藏会话的时间线都要重新排版,标签越多越卡。失活时记住当时的尺寸并固定,重新激活时再跟随容器。
struct InactiveSizeFreeze: ViewModifier {
    /// 标签是否处于活动状态
    let isActive: Bool
    /// 容器当前尺寸
    let size: CGSize
    @State private var frozen: CGSize?

    func body(content: Content) -> some View {
        // 活动时始终跟随容器(激活当帧就是正确尺寸);失活后才使用记住的尺寸
        let fixed = isActive ? size : (frozen ?? size)
        content
            .frame(width: fixed.width, height: fixed.height)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .onChange(of: isActive, initial: true) { _, active in frozen = active ? nil : size }
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
                RoundedRectangle(cornerRadius: OMRadius.tag)
                    .fill(OMColors.selectedFill)
                    .overlay(RoundedRectangle(cornerRadius: OMRadius.tag).strokeBorder(OMColors.accent.opacity(0.7), lineWidth: 1.5))
                    .frame(width: rect.width - 8, height: rect.height - 8)
                    .position(x: rect.midX, y: rect.midY)
                    .transition(.opacity)
            }
        }
    }
}


/// 把从 Finder/资源管理器拖入的文件在标签区打开。
@MainActor
enum DockFileDrop {
    /// 是否为外部文件拖入(不是应用内标签拖拽)。
    static func isFileDrop(_ info: DropInfo) -> Bool {
        DockDrag.shared.tabID == nil && info.hasItemsConforming(to: [.fileURL])
    }

    /// 读取拖入的文件 URL,过滤出存在的普通文件后回调。
    /// - Parameters:
    ///   - info: 放下信息
    ///   - completion: 主线程回调(文件路径列表)
    static func loadFiles(_ info: DropInfo, completion: @escaping @MainActor ([String]) -> Void) {
        let providers = info.itemProviders(for: [.fileURL])
        Task { @MainActor in
            var urls: [URL] = []
            for provider in providers {
                let url: URL? = await withCheckedContinuation { continuation in
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
                }
                if let url { urls.append(url) }
            }
            let files = DropClassifier.classify(urls).filter { $0.kind != .directory }.map(\.url.path)
            completion(files)
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
        (info.hasItemsConforming(to: [.plainText]) && DockDrag.shared.tabID != nil) || DockFileDrop.isFileDrop(info)
    }

    func dropEntered(info: DropInfo) { zone = DockDropZone.zone(at: info.location, in: size) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        zone = DockDropZone.zone(at: info.location, in: size)
        return DropProposal(operation: DockFileDrop.isFileDrop(info) ? .copy : .move)
    }

    func dropExited(info: DropInfo) { zone = nil }

    func performDrop(info: DropInfo) -> Bool {
        let target = zone ?? DockDropZone.zone(at: info.location, in: size)
        zone = nil
        if DockFileDrop.isFileDrop(info) {
            let model = workbench, group = groupID
            DockFileDrop.loadFiles(info) { paths in
                model.dock.focus(group: group)
                for path in paths {
                    let id = model.openFile(path, preview: false)
                    // 落在边缘:新建分屏;落在中心:并入该组
                    model.dock.drop(id, onGroup: group, zone: target)
                }
                model.syncSelectionFromDock()
            }
            return true
        }
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
        (info.hasItemsConforming(to: [.plainText]) && DockDrag.shared.tabID != nil) || DockFileDrop.isFileDrop(info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: DockFileDrop.isFileDrop(info) ? .copy : .move) }

    func performDrop(info: DropInfo) -> Bool {
        if DockFileDrop.isFileDrop(info) {
            let model = workbench, group = groupID, at = index
            DockFileDrop.loadFiles(info) { paths in
                model.dock.focus(group: group)
                var position = at
                for path in paths {
                    let id = model.openFile(path, preview: false)
                    model.dock.move(id, toGroup: group, at: position)
                    position = position.map { $0 + 1 }
                }
                model.syncSelectionFromDock()
            }
            return true
        }
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
