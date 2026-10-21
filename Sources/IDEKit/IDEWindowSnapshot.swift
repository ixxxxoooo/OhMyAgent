// @author ixxxxoooo
// IDE 窗口的可持久化快照与布局度量:纯值类型,无视图,可直接编码为 `ide-windows.json`。

import Foundation
import WorkbenchKit

/// IDE 侧栏当前显示的视图(活动栏三个入口)。
public enum IDESidebarView: String, Codable, CaseIterable, Sendable {
    /// 资源管理器
    case explorer
    /// 全局搜索
    case search
    /// 源代码管理
    case scm
}

/// 底部面板的标签页。
public enum IDEPanelTab: String, Codable, CaseIterable, Sendable {
    /// 终端
    case terminal
    /// 问题(诊断)
    case problems
    /// 输出(日志)
    case output
}

/// 窗口外框(屏幕坐标,点)。
public struct IDEWindowFrame: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    /// - Parameters:
    ///   - x: 左边缘
    ///   - y: 下边缘
    ///   - width: 宽度
    ///   - height: 高度
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// 是否为有限且有面积的外框(防止损坏的存档产生不可见窗口)。
    public var isUsable: Bool {
        [x, y, width, height].allSatisfy(\.isFinite) && width >= IDEMetrics.windowMinWidth && height >= IDEMetrics.windowMinHeight
    }
}

/// IDE 外壳的尺寸范围、默认值与换算(纯函数,便于测试)。
public enum IDEMetrics {
    /// 活动栏宽度
    public static let activityBarWidth: Double = 48
    /// 标题栏高度(与 Agent 窗口的 `TitlebarMetrics.height` 一致)
    public static let titleBarHeight: Double = 35
    /// 状态栏高度
    public static let statusBarHeight: Double = 22
    /// 窗口最小尺寸
    public static let windowMinWidth: Double = 640
    public static let windowMinHeight: Double = 420
    /// 窗口默认尺寸
    public static let windowDefaultWidth: Double = 1280
    public static let windowDefaultHeight: Double = 820
    /// 侧栏宽度范围与默认值
    public static let sidebarRange: ClosedRange<Double> = 180...520
    public static let sidebarDefault: Double = 260
    /// 底部面板高度范围与默认值
    public static let panelRange: ClosedRange<Double> = 120...800
    public static let panelDefault: Double = 240
    /// Agent 面板宽度范围与默认值
    public static let agentRange: ClosedRange<Double> = 280...900
    public static let agentDefault: Double = 380
    /// 编辑区至少保留的宽度与高度(拖分隔条时据此钳制)
    public static let editorMinWidth: Double = 320
    public static let editorMinHeight: Double = 160

    /// 把值限制在范围内;非有限值取默认值。
    /// - Parameters:
    ///   - value: 期望值
    ///   - range: 允许范围
    ///   - fallback: 非有限值时的回退
    public static func clamp(_ value: Double, to range: ClosedRange<Double>, fallback: Double) -> Double {
        guard value.isFinite else { return fallback }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    /// 在给定窗口内,侧栏宽度的实际上限:让出活动栏、Agent 面板与编辑区最小宽度后剩余的空间。
    /// - Parameters:
    ///   - window: 窗口内容宽度
    ///   - agentWidth: Agent 面板占用宽度(收起为 0)
    public static func sidebarMax(window: Double, agentWidth: Double) -> Double {
        max(sidebarRange.lowerBound, min(sidebarRange.upperBound, window - activityBarWidth - agentWidth - editorMinWidth))
    }

    /// 在给定窗口内,Agent 面板宽度的实际上限。
    /// - Parameters:
    ///   - window: 窗口内容宽度
    ///   - sidebarWidth: 侧栏占用宽度(收起为 0)
    public static func agentMax(window: Double, sidebarWidth: Double) -> Double {
        max(agentRange.lowerBound, min(agentRange.upperBound, window - activityBarWidth - sidebarWidth - editorMinWidth))
    }

    /// 在给定窗口内,底部面板高度的实际上限:让出标题栏、状态栏与编辑区最小高度。
    /// - Parameter window: 窗口内容高度
    public static func panelMax(window: Double) -> Double {
        max(panelRange.lowerBound, min(panelRange.upperBound, window - titleBarHeight - statusBarHeight - editorMinHeight))
    }

    /// 规范化工作区路径作为「同一根目录」的比较键:标准化并解析符号链接,去掉末尾斜杠。
    /// - Parameter path: 目录路径
    /// - Returns: 规范化后的路径;空串返回 nil
    public static func normalizedRoot(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        let resolved = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        return resolved.count > 1 && resolved.hasSuffix("/") ? String(resolved.dropLast()) : resolved
    }
}

/// 一个 IDE 窗口的持久化快照。
public struct IDEWindowSnapshot: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    /// 工作区根目录(规范化路径);空窗口为 nil
    public var workspaceRoot: String?
    public var sidebarView: IDESidebarView
    public var sidebarVisible: Bool
    public var sidebarWidth: Double
    public var panelVisible: Bool
    public var panelHeight: Double
    /// 底部面板当前标签页(旧版本存档没有该字段,为 nil 时取终端)
    public var panelTab: IDEPanelTab?
    public var agentPaneVisible: Bool
    public var agentPaneWidth: Double
    /// 窗口外框(尚未记录时为 nil,首次显示用默认尺寸)
    public var frame: IDEWindowFrame?
    /// 编辑器停靠布局(标签与分屏)
    public var editor: DockLayout
    /// 最近一次激活时间
    public var lastActivated: Date

    /// - Parameters:
    ///   - id: 窗口标识
    ///   - workspaceRoot: 工作区根目录
    public init(id: UUID = UUID(), workspaceRoot: String? = nil) {
        self.id = id
        self.workspaceRoot = IDEMetrics.normalizedRoot(workspaceRoot)
        sidebarView = .explorer
        sidebarVisible = true
        sidebarWidth = IDEMetrics.sidebarDefault
        panelVisible = false
        panelHeight = IDEMetrics.panelDefault
        agentPaneVisible = true
        agentPaneWidth = IDEMetrics.agentDefault
        frame = nil
        editor = DockLayout()
        lastActivated = Date()
    }

    /// 钳制尺寸到合法范围(解码损坏或手改文件后调用)。
    public mutating func clamp() {
        sidebarWidth = IDEMetrics.clamp(sidebarWidth, to: IDEMetrics.sidebarRange, fallback: IDEMetrics.sidebarDefault)
        panelHeight = IDEMetrics.clamp(panelHeight, to: IDEMetrics.panelRange, fallback: IDEMetrics.panelDefault)
        agentPaneWidth = IDEMetrics.clamp(agentPaneWidth, to: IDEMetrics.agentRange, fallback: IDEMetrics.agentDefault)
        if let current = frame, !current.isUsable { frame = nil }
    }
}

/// `ide-windows.json` 的文件内容:窗口按最近使用顺序排列(首个最新)。
public struct IDEWindowsState: Codable, Equatable, Sendable {
    /// 格式版本
    public var version: Int
    public var windows: [IDEWindowSnapshot]

    /// 当前格式版本。
    public static let currentVersion = 1

    /// - Parameter windows: 窗口快照(最近使用在前)
    public init(windows: [IDEWindowSnapshot] = []) {
        version = Self.currentVersion
        self.windows = windows
    }
}
