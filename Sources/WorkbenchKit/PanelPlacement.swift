// @author ixxxxoooo
// 面板摆放模型:项目栏与工具栏(右栏停靠区)所在的一侧,以及拖动它们到左/右半边时的落点判定。
// 终端、输出等已经是右栏停靠区(`rightDock`)里的普通标签,不再有独立的摆放位置。无视图,便于测试。

import CoreGraphics
import Foundation

/// 可摆放的面板列。
public enum PanelColumn: String, CaseIterable, Identifiable, Sendable {
    /// 项目与会话树
    case sidebar
    /// 工具栏:右栏停靠区(终端 / 输出 / 文件预览 / Plan / 资源管理器 / Git / 搜索 / 浏览器)
    case tools

    public var id: String { rawValue }
}

/// 面板摆放配置(持久化在 `workbench.json` 的布局里)。旧版本里的 `terminal`/`output` 键被忽略。
public struct PanelPlacement: Codable, Equatable, Sendable {
    /// 项目栏所在侧
    public var sidebarSide: PanelSide = .left
    /// 工具栏(右栏停靠区)所在侧
    public var toolsSide: PanelSide = .right

    public init() {}

    public init(sidebarSide: PanelSide = .left, toolsSide: PanelSide = .right) {
        self.sidebarSide = sidebarSide
        self.toolsSide = toolsSide
    }

    private enum CodingKeys: String, CodingKey { case sidebarSide, toolsSide }

    /// 容错解码:字段缺失或取值未知时回落到默认值。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sidebarSide = (try? c.decodeIfPresent(PanelSide.self, forKey: .sidebarSide)) ?? .left
        toolsSide = (try? c.decodeIfPresent(PanelSide.self, forKey: .toolsSide)) ?? .right
    }
}

public extension WorkbenchLayout {
    /// 某列所在的一侧。
    func side(of column: PanelColumn) -> PanelSide {
        switch column {
        case .sidebar: return placement.sidebarSide
        case .tools: return placement.toolsSide
        }
    }

    /// 某列当前是否可见。
    func isVisible(_ column: PanelColumn) -> Bool {
        switch column {
        case .sidebar: return leftVisible
        case .tools: return rightVisible
        }
    }

    /// 某一侧的全部列(不论是否可见),由外向内:项目栏、工具栏。
    func columns(on side: PanelSide) -> [PanelColumn] {
        PanelColumn.allCases.filter { self.side(of: $0) == side }
    }

    /// 某一侧当前可见的列,由外向内。
    func visibleColumns(on side: PanelSide) -> [PanelColumn] {
        columns(on: side).filter { isVisible($0) }
    }

    /// 某一侧的开关按钮数量(项目栏、工具栏各一个)。
    func toggleCount(on side: PanelSide) -> Int {
        columns(on: side).count
    }

    /// 某列的宽度。
    func width(of column: PanelColumn) -> Double {
        switch column {
        case .sidebar: return leftWidth
        case .tools: return rightWidth
        }
    }
}

/// 窗口里的摆放区域(项目栏与工具栏只能在左右两侧)。
public enum PanelZone: String, CaseIterable, Identifiable, Sendable {
    case left, right

    public var id: String { rawValue }

    /// 对应的侧。
    public var side: PanelSide { self == .left ? .left : .right }

    /// 拖动时高亮的区域(工作区内坐标):对应侧的 1/4 宽度。
    /// - Parameters:
    ///   - size: 工作区尺寸
    ///   - edgeFraction: 边缘区占比
    /// - Returns: 高亮矩形
    public func highlight(in size: CGSize, edgeFraction: Double = 0.25) -> CGRect {
        let ew = size.width * edgeFraction
        return self == .left ? CGRect(x: 0, y: 0, width: ew, height: size.height) : CGRect(x: size.width - ew, y: 0, width: ew, height: size.height)
    }
}

/// 可摆放的面板条目(外观页的拖拽布局编辑器、标题区拖动手柄使用)。
public enum PanelItem: String, CaseIterable, Identifiable, Sendable {
    /// 项目与会话树
    case sidebar
    /// 右栏停靠区
    case tools

    public var id: String { rawValue }

    /// 拖拽载荷前缀。
    public static let payloadPrefix = "oma-panel:"

    /// 拖拽载荷。
    public var payload: String { Self.payloadPrefix + rawValue }

    /// 由拖拽载荷解析面板条目。
    /// - Parameter payload: 载荷文本
    public static func parse(payload: String) -> PanelItem? {
        guard payload.hasPrefix(payloadPrefix) else { return nil }
        return PanelItem(rawValue: String(payload.dropFirst(payloadPrefix.count)))
    }

    /// 由指针位置判定拖动该面板时的落点(按左右半幅);指针在工作区之外返回 nil(松手即取消)。
    /// - Parameters:
    ///   - point: 工作区内坐标(左上为原点)
    ///   - size: 工作区尺寸
    /// - Returns: 落点;越界为 nil
    public func dropTarget(at point: CGPoint, in size: CGSize) -> PanelZone? {
        guard size.width > 0, size.height > 0,
              point.x >= 0, point.y >= 0, point.x <= size.width, point.y <= size.height else { return nil }
        return point.x < size.width / 2 ? .left : .right
    }

    /// 该面板可以去的区域。
    public var allowedZones: [PanelZone] { PanelZone.allCases }
}

public extension WorkbenchLayout {
    /// 面板条目当前所在区域。
    /// - Parameter item: 面板条目
    func zone(of item: PanelItem) -> PanelZone {
        switch item {
        case .sidebar: return placement.sidebarSide == .left ? .left : .right
        case .tools: return placement.toolsSide == .left ? .left : .right
        }
    }

    /// 某区域里摆放的全部面板(项目栏、工具栏的固定顺序)。
    /// - Parameter zone: 区域
    func items(in zone: PanelZone) -> [PanelItem] {
        PanelItem.allCases.filter { self.zone(of: $0) == zone }
    }
}

@MainActor
public extension WorkbenchModel {
    /// 把面板放到某个区域(拖拽布局编辑器、标题区拖动的落点处理)。
    /// - Parameters:
    ///   - item: 面板条目
    ///   - zone: 目标区域
    /// - Returns: 是否生效
    @discardableResult
    func place(_ item: PanelItem, in zone: PanelZone) -> Bool {
        guard item.allowedZones.contains(zone) else { return false }
        switch item {
        case .sidebar: setSidebarSide(zone.side)
        case .tools: setToolsSide(zone.side)
        }
        return true
    }
}
