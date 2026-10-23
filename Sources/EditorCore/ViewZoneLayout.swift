// @author ixxxxoooo
// View Zone:挂在某模型行之后、占据一块整行宽度高度的「行间区域」(行内 Diff 的删除块、Peek、⌘K 输入条、幽灵文本块等)。
// 布局把视图行与 Zone 高度合成统一的 y 坐标,并支持 y → 行/Zone 的命中查询。

import Foundation

/// 一个 View Zone。
public struct ViewZone: Sendable, Hashable, Identifiable {
    /// 唯一标识(由调用方分配)。
    public var id: Int
    /// 挂在该模型行之后;`-1` 表示第一行之前。
    public var afterLine: Int
    /// 高度(点)。
    public var height: Double

    public init(id: Int, afterLine: Int, height: Double) {
        self.id = id
        self.afterLine = max(-1, afterLine)
        self.height = max(0, height)
    }
}

/// y 坐标命中结果。
public enum ViewZoneHit: Sendable, Equatable {
    /// 命中视图行 `row`,`offset` 为行内 y 偏移。
    case row(Int, offset: Double)
    /// 命中第 `index` 个 Zone(布局顺序),`offset` 为 Zone 内 y 偏移。
    case zone(index: Int, offset: Double)
}

/// View Zone 布局:行高固定,Zone 高度各异。
public struct ViewZoneLayout: Sendable {
    /// 行高(点)。
    public private(set) var lineHeight: Double
    /// 布局顺序的 Zone(按锚点视图行升序)。
    public private(set) var zones: [ViewZone] = []
    /// 每个 Zone 前方的视图行数(Zone 位于该行之前)。
    private var anchorRows: [Int] = []
    /// 每个 Zone 之前所有 Zone 的高度之和。
    private var cumulativeBefore: [Double] = []
    /// 全部 Zone 高度之和。
    public private(set) var totalZoneHeight: Double = 0

    /// 创建布局。
    public init(lineHeight: Double) { self.lineHeight = max(1, lineHeight) }

    /// 更新行高。
    public mutating func setLineHeight(_ value: Double) { lineHeight = max(1, value) }

    /// 重新布局:折叠隐藏行上的 Zone 不显示。
    /// - Parameters:
    ///   - input: 全部 Zone
    ///   - map: 当前视图行映射
    public mutating func update(zones input: [ViewZone], map: ViewLineMap) {
        var placed: [(zone: ViewZone, anchor: Int)] = []
        placed.reserveCapacity(input.count)
        for zone in input {
            if zone.afterLine >= map.lineCount { continue }
            if zone.afterLine >= 0, map.isHidden(line: zone.afterLine) { continue }
            let anchor = zone.afterLine < 0 ? 0 : map.firstRow(ofLine: zone.afterLine + 1)
            placed.append((zone, anchor))
        }
        placed.sort { $0.anchor != $1.anchor ? $0.anchor < $1.anchor : $0.zone.id < $1.zone.id }
        zones = placed.map(\.zone)
        anchorRows = placed.map(\.anchor)
        cumulativeBefore = []
        cumulativeBefore.reserveCapacity(zones.count)
        var running = 0.0
        for zone in zones {
            cumulativeBefore.append(running)
            running += zone.height
        }
        totalZoneHeight = running
    }

    /// 视图行顶部的 y 坐标(含其前方所有 Zone 的高度)。
    public func y(ofRow row: Int) -> Double {
        // 锚点 ≤ row 的 Zone 都位于该行之前。
        let count = anchorsNotAfter(row)
        let before = count == 0 ? 0 : cumulativeBefore[count - 1] + zones[count - 1].height
        return Double(row) * lineHeight + before
    }

    /// 第 `index` 个 Zone 顶部的 y 坐标。
    public func y(ofZoneAt index: Int) -> Double {
        guard index >= 0, index < zones.count else { return 0 }
        return Double(anchorRows[index]) * lineHeight + cumulativeBefore[index]
    }

    /// 文档总高度。
    public func contentHeight(totalRows: Int) -> Double { Double(totalRows) * lineHeight + totalZoneHeight }

    /// y 坐标命中的行或 Zone;`y < 0` 视为第 0 行。
    public func hit(y yCoordinate: Double, totalRows: Int) -> ViewZoneHit {
        let position = max(0, yCoordinate)
        // 二分:最后一个起点 ≤ position 的 Zone。
        var low = 0, high = zones.count - 1, found = -1
        while low <= high {
            let mid = (low + high) / 2
            if y(ofZoneAt: mid) <= position { found = mid; low = mid + 1 } else { high = mid - 1 }
        }
        if found >= 0 {
            let start = y(ofZoneAt: found)
            if position < start + zones[found].height { return .zone(index: found, offset: position - start) }
            let rowsAfter = (position - (start + zones[found].height)) / lineHeight
            let row = min(anchorRows[found] + Int(rowsAfter), max(totalRows - 1, 0))
            return .row(row, offset: position - y(ofRow: row))
        }
        let row = min(Int(position / lineHeight), max(totalRows - 1, 0))
        return .row(row, offset: position - Double(row) * lineHeight)
    }

    /// 第 `index` 个 Zone 的锚点视图行(Zone 位于该行之前)。
    public func anchorRow(ofZoneAt index: Int) -> Int { anchorRows[index] }

    /// 锚点视图行 ≤ `row` 的 Zone 个数。
    private func anchorsNotAfter(_ row: Int) -> Int {
        var low = 0, high = anchorRows.count
        while low < high {
            let mid = (low + high) / 2
            if anchorRows[mid] <= row { low = mid + 1 } else { high = mid }
        }
        return low
    }
}
