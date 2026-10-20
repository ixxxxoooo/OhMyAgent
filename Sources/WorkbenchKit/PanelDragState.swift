// @author ixxxxoooo
// 面板拖动中的临时尺寸:拖分栏时每个 tick 只写这里,松手才一次性提交到 `WorkbenchLayout`。
// 背景:`WorkbenchModel.layout` 是整个结构体,逐 tick 写入会让所有读取 layout 任一字段的视图
// (工作台根视图、标签条、右栏、标题栏、底部面板、主菜单)全部重算;临时值按列独立观察,只刷新被拖动的那一列。

import Foundation
import Observation

/// 可被拖动调整的尺寸维度。
public enum PanelDimension: CaseIterable, Hashable, Sendable {
    /// 项目栏宽度
    case leftWidth
    /// 工具栏宽度
    case rightWidth
    /// 终端面板内右侧终端列表的宽度
    case terminalListWidth

    /// 该维度允许的取值范围。
    public var range: ClosedRange<Double> {
        switch self {
        case .leftWidth: PanelMetrics.leftRange
        case .rightWidth: PanelMetrics.rightRange
        case .terminalListWidth: PanelMetrics.terminalListRange
        }
    }

    /// 某个面板列对应的宽度维度。
    /// - Parameter column: 面板列
    public init(column: PanelColumn) {
        switch column {
        case .sidebar: self = .leftWidth
        case .tools: self = .rightWidth
        }
    }

    /// 读取布局中该维度的已提交值。
    /// - Parameter layout: 工作台布局
    public func committed(in layout: WorkbenchLayout) -> Double {
        switch self {
        case .leftWidth: layout.leftWidth
        case .rightWidth: layout.rightWidth
        case .terminalListWidth: layout.terminalListWidth
        }
    }

    /// 把值(先钳制到范围)写入布局;值未变化时不写,避免无谓的失效与落盘。
    /// - Parameters:
    ///   - value: 新值
    ///   - layout: 工作台布局(原地修改)
    public func write(_ value: Double, to layout: inout WorkbenchLayout) {
        let clamped = clamp(value)
        guard committed(in: layout) != clamped else { return }
        switch self {
        case .leftWidth: layout.leftWidth = clamped
        case .rightWidth: layout.rightWidth = clamped
        case .terminalListWidth: layout.terminalListWidth = clamped
        }
    }

    /// 把值限制在允许范围内;非有限值取下限。
    /// - Parameter value: 期望值
    public func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return range.lowerBound }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}

/// 拖动中的临时尺寸(每个维度一个可选属性,按属性独立观察)。
@MainActor
@Observable
public final class PanelDragState {
    /// 全局实例(应用层视图共用)。
    public static let shared = PanelDragState()

    public init() {}

    private var leftWidth: Double?
    private var rightWidth: Double?
    private var terminalListWidth: Double?

    /// 正在拖动的维度(不参与观察,供 AppKit 侧的实时缩放门控读取)。
    @ObservationIgnored public private(set) var activeDimensions: Set<PanelDimension> = []

    /// 外部拖动占位计数(编辑区分屏等不走临时尺寸的分隔条拖动,用于让终端等重排昂贵的视图也进入门控)。
    @ObservationIgnored public private(set) var holdCount = 0

    /// 当前是否有任何分隔条处于拖动中。
    public var isDragging: Bool { !activeDimensions.isEmpty || holdCount > 0 }

    /// 外部拖动开始(与 `endHold()` 成对;重复调用按计数累计)。
    public func beginHold() { holdCount += 1 }

    /// 外部拖动结束。
    public func endHold() { holdCount = max(holdCount - 1, 0) }

    /// 读取某维度的拖动中临时值;只订阅该维度。
    /// - Parameter dimension: 尺寸维度
    /// - Returns: 临时值;未在拖动返回 nil
    public func value(of dimension: PanelDimension) -> Double? {
        switch dimension {
        case .leftWidth: leftWidth
        case .rightWidth: rightWidth
        case .terminalListWidth: terminalListWidth
        }
    }

    /// 有效值:拖动中取临时值,否则取布局里已提交的值。
    /// - Parameters:
    ///   - dimension: 尺寸维度
    ///   - layout: 工作台布局(提供已提交值)
    public func effective(_ dimension: PanelDimension, committed layout: WorkbenchLayout) -> Double {
        value(of: dimension) ?? dimension.committed(in: layout)
    }

    /// 拖动中更新临时值(钳制到范围;与当前临时值相同则不写)。
    /// - Parameters:
    ///   - value: 期望值
    ///   - dimension: 尺寸维度
    public func update(_ value: Double, for dimension: PanelDimension) {
        let clamped = dimension.clamp(value)
        activeDimensions.insert(dimension)
        guard self.value(of: dimension) != clamped else { return }
        store(clamped, for: dimension)
    }

    /// 拖动结束:把临时值提交到布局并清除临时状态。
    /// - Parameters:
    ///   - dimension: 尺寸维度
    ///   - layout: 工作台布局(原地修改;仅在值变化时才真正写入)
    /// - Returns: 是否改变了布局
    @discardableResult
    public func commit(_ dimension: PanelDimension, to layout: inout WorkbenchLayout) -> Bool {
        defer { cancel(dimension) }
        guard let pending = value(of: dimension), dimension.committed(in: layout) != pending else { return false }
        dimension.write(pending, to: &layout)
        return true
    }

    /// 放弃临时值(不提交)。
    /// - Parameter dimension: 尺寸维度
    public func cancel(_ dimension: PanelDimension) {
        activeDimensions.remove(dimension)
        if value(of: dimension) != nil { store(nil, for: dimension) }
    }

    private func store(_ value: Double?, for dimension: PanelDimension) {
        switch dimension {
        case .leftWidth: leftWidth = value
        case .rightWidth: rightWidth = value
        case .terminalListWidth: terminalListWidth = value
        }
    }
}
