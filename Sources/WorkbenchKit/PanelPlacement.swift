// @author ixxxxoooo
// 面板摆放模型:终端放在底部/右栏/左栏/编辑区(标签),项目栏与工具栏(文件/搜索/Git)所在的一侧;
// 以及拖动终端到各区域时的落点判定(复用停靠区的五区命中测试)。无视图,便于测试。

import CoreGraphics
import Foundation

/// 终端的摆放位置。
public enum TerminalPlacement: String, Codable, CaseIterable, Sendable {
    /// 底部面板(默认)
    case bottom
    /// 右侧栏
    case right
    /// 左侧栏
    case left
    /// 编辑区(作为一个终端标签)
    case editor

    /// 是否为左/右侧栏位置。
    public var isSide: Bool { self == .left || self == .right }

    /// 对应的物理一侧(仅左/右有值)。
    public var side: PanelSide? {
        switch self {
        case .left: return .left
        case .right: return .right
        default: return nil
        }
    }

    /// 由停靠区五区命中结果换算成终端位置:左/右/下边缘吸附到对应位置,中心与上边缘放进编辑区。
    /// - Parameter zone: 停靠落点
    /// - Returns: 终端位置
    public static func from(zone: DockDropZone) -> TerminalPlacement {
        switch zone {
        case .left: return .left
        case .right: return .right
        case .bottom: return .bottom
        case .center, .top: return .editor
        }
    }

    /// 由指针位置判定拖动终端时的落点;指针在工作区之外返回 nil(松手即取消)。
    /// - Parameters:
    ///   - point: 工作区内坐标(左上为原点)
    ///   - size: 工作区尺寸
    ///   - edgeFraction: 边缘区占比
    /// - Returns: 落点;越界为 nil
    public static func dropTarget(at point: CGPoint, in size: CGSize, edgeFraction: Double = 0.25) -> TerminalPlacement? {
        guard size.width > 0, size.height > 0,
              point.x >= 0, point.y >= 0, point.x <= size.width, point.y <= size.height else { return nil }
        return from(zone: DockDropZone.zone(at: point, in: size, edgeFraction: edgeFraction))
    }

    /// 拖动时高亮的区域(工作区内坐标)。
    /// - Parameters:
    ///   - size: 工作区尺寸
    ///   - edgeFraction: 边缘区占比
    /// - Returns: 高亮矩形
    public func highlight(in size: CGSize, edgeFraction: Double = 0.25) -> CGRect {
        let w = size.width, h = size.height
        let ew = w * edgeFraction, eh = h * edgeFraction
        switch self {
        case .left: return CGRect(x: 0, y: 0, width: ew, height: h)
        case .right: return CGRect(x: w - ew, y: 0, width: ew, height: h)
        case .bottom: return CGRect(x: 0, y: h - eh, width: w, height: eh)
        case .editor: return CGRect(x: ew, y: 0, width: max(0, w - ew * 2), height: max(0, h - eh))
        }
    }
}

/// 可摆放的面板列。
public enum PanelColumn: String, CaseIterable, Identifiable, Sendable {
    /// 项目与会话树
    case sidebar
    /// 工具栏:文件 / 搜索 / Git
    case tools
    /// 终端侧栏
    case terminal

    public var id: String { rawValue }
}

/// 面板摆放配置(持久化在 `workbench.json` 的布局里)。
public struct PanelPlacement: Codable, Equatable, Sendable {
    /// 终端位置
    public var terminal: TerminalPlacement = .bottom
    /// 项目栏所在侧
    public var sidebarSide: PanelSide = .left
    /// 工具栏(文件/搜索/Git)所在侧
    public var toolsSide: PanelSide = .right

    public init() {}

    public init(terminal: TerminalPlacement = .bottom, sidebarSide: PanelSide = .left, toolsSide: PanelSide = .right) {
        self.terminal = terminal
        self.sidebarSide = sidebarSide
        self.toolsSide = toolsSide
    }

    private enum CodingKeys: String, CodingKey { case terminal, sidebarSide, toolsSide }

    /// 容错解码:字段缺失或取值未知时回落到默认值。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        terminal = (try? c.decodeIfPresent(TerminalPlacement.self, forKey: .terminal)) ?? .bottom
        sidebarSide = (try? c.decodeIfPresent(PanelSide.self, forKey: .sidebarSide)) ?? .left
        toolsSide = (try? c.decodeIfPresent(PanelSide.self, forKey: .toolsSide)) ?? .right
    }
}

public extension WorkbenchLayout {
    /// 某列所在的一侧;终端不在左/右侧栏时返回 nil。
    func side(of column: PanelColumn) -> PanelSide? {
        switch column {
        case .sidebar: return placement.sidebarSide
        case .tools: return placement.toolsSide
        case .terminal: return placement.terminal.side
        }
    }

    /// 某列当前是否可见。
    func isVisible(_ column: PanelColumn) -> Bool {
        switch column {
        case .sidebar: return leftVisible
        case .tools: return rightVisible
        case .terminal: return terminalVisible && placement.terminal.isSide
        }
    }

    /// 某一侧的全部列(不论是否可见),由外向内:项目栏、工具栏、终端。
    func columns(on side: PanelSide) -> [PanelColumn] {
        PanelColumn.allCases.filter { self.side(of: $0) == side }
    }

    /// 某一侧当前可见的列,由外向内。
    func visibleColumns(on side: PanelSide) -> [PanelColumn] {
        columns(on: side).filter { isVisible($0) }
    }

    /// 某一侧的开关按钮数量(项目栏、工具栏各一个;终端侧栏没有标题栏开关)。
    func toggleCount(on side: PanelSide) -> Int {
        columns(on: side).filter { $0 != .terminal }.count
    }

    /// 某列的宽度。
    func width(of column: PanelColumn) -> Double {
        switch column {
        case .sidebar: return leftWidth
        case .tools: return rightWidth
        case .terminal: return terminalWidth
        }
    }
}
