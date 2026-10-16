// @author ixxxxoooo
// Git Graph 布局:把按时间排序的提交列表转换成"泳道"行,供视图画出分支/合并线。
// 纯函数、无 UI 依赖;每条泳道有稳定的颜色序号,沿首个父提交延续同色。

import Foundation

/// 一条泳道(某一列上等待出现的下一个提交)。
public struct GitGraphLane: Sendable, Hashable {
    /// 这条线下一个要到达的提交
    public var hash: String
    /// 颜色序号(由视图对调色板取模)
    public var color: Int
}

/// 图中的一行(对应一个提交)。
public struct GitGraphRow: Sendable, Hashable, Identifiable {
    public var id: String { commit.hash }
    public var commit: GitCommit
    /// 提交点所在列
    public var column: Int
    /// 提交点颜色序号
    public var color: Int
    /// 行顶部各列的泳道(nil 表示该列空)
    public var top: [GitGraphLane?]
    /// 行底部各列的泳道
    public var bottom: [GitGraphLane?]
    /// 汇入该提交的列(顶部泳道中指向本提交的列,含 `column` 自身)
    public var incoming: [Int]
    /// 从该提交向下分出的列(各父提交所在的底部列)
    public var outgoing: [Int]

    public init(commit: GitCommit, column: Int, color: Int, top: [GitGraphLane?], bottom: [GitGraphLane?], incoming: [Int], outgoing: [Int]) {
        self.commit = commit
        self.column = column
        self.color = color
        self.top = top
        self.bottom = bottom
        self.incoming = incoming
        self.outgoing = outgoing
    }

    /// 本行需要的列数。
    public var laneCount: Int { max(top.count, bottom.count, column + 1) }
}

public enum GitGraph {
    /// 计算图布局。
    /// - Parameter commits: 新→旧排列的提交(`git log --date-order` 的顺序)
    /// - Returns: 与输入等长的行
    public static func layout(_ commits: [GitCommit]) -> [GitGraphRow] {
        var lanes: [GitGraphLane?] = []
        var nextColor = 0
        var rows: [GitGraphRow] = []
        rows.reserveCapacity(commits.count)

        func firstFree(in lanes: [GitGraphLane?]) -> Int {
            lanes.firstIndex(where: { $0 == nil }) ?? lanes.count
        }

        for commit in commits {
            let top = lanes
            let incoming = lanes.indices.filter { lanes[$0]?.hash == commit.hash }
            let column: Int
            let color: Int
            if let first = incoming.first, let lane = lanes[first] {
                column = first
                color = lane.color
            } else {
                // 没有泳道指向它(分支末端的最新提交):占用第一个空位并分配新颜色
                column = firstFree(in: lanes)
                color = nextColor
                nextColor += 1
                if column == lanes.count { lanes.append(nil) }
            }
            // 所有指向本提交的泳道在此汇合并释放
            for index in incoming { lanes[index] = nil }

            var outgoing: [Int] = []
            for (offset, parent) in commit.parents.enumerated() {
                if let existing = lanes.firstIndex(where: { $0?.hash == parent }) {
                    // 父提交已在某条泳道里等待:连过去即可
                    outgoing.append(existing)
                    continue
                }
                let slot: Int
                let laneColor: Int
                if offset == 0 {
                    // 首父沿用本提交的列与颜色
                    slot = lanes.indices.contains(column) && lanes[column] == nil ? column : firstFree(in: lanes)
                    laneColor = color
                } else {
                    slot = firstFree(in: lanes)
                    laneColor = nextColor
                    nextColor += 1
                }
                if slot == lanes.count { lanes.append(nil) }
                lanes[slot] = GitGraphLane(hash: parent, color: laneColor)
                outgoing.append(slot)
            }
            while let last = lanes.last, last == nil { lanes.removeLast() }
            rows.append(GitGraphRow(commit: commit, column: column, color: color, top: top, bottom: lanes,
                                    incoming: incoming, outgoing: outgoing))
        }
        return rows
    }
}
