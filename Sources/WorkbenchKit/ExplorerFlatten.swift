// @author ixxxxoooo
// 资源管理器文件树的扁平化与窗口化(纯逻辑,无视图):
// 把「根 → 展开的目录 → 子项」展平成一维行数组,配合固定行高只挂载可见窗口内的行,
// 展开数千行的目录时挂载与滚动成本只与可见行数相关,而与总行数无关。

import Foundation

/// 资源管理器的一棵根目录来源。
public struct ExplorerSource: Hashable, Sendable {
    /// 根目录绝对路径
    public let root: String
    /// 是否显示根节点本身的标题行(多文件夹工作区的附加文件夹显示,项目根不显示)
    public let showsHeader: Bool

    /// - Parameters:
    ///   - root: 根目录绝对路径
    ///   - showsHeader: 是否显示根节点标题行
    public init(root: String, showsHeader: Bool) {
        self.root = root
        self.showsHeader = showsHeader
    }
}

/// 展平后的一行。
public struct ExplorerRowItem: Identifiable, Hashable, Sendable {
    /// 条目(文件、文件夹或附加文件夹根)
    public let entry: FileEntry
    /// 缩进层级
    public let depth: Int
    /// 所属根目录(用于 Git 装饰与相对路径)
    public let root: String
    /// 是否为附加文件夹的根标题行
    public let isRootHeader: Bool
    /// 是否展开(仅目录有意义)
    public let isExpanded: Bool

    public var id: String { entry.path }
}

/// 文件树展平与可见窗口计算。
public enum ExplorerFlatten {
    /// 把各根目录的树按展开状态展平成行。
    /// - Parameters:
    ///   - sources: 根目录来源(按显示顺序)
    ///   - children: 目录路径 → 已列举的子项(未加载的目录视为没有子项)
    ///   - expanded: 已展开的目录路径(带标题行的根也靠它判断展开)
    /// - Returns: 从上到下的行
    public static func rows(sources: [ExplorerSource], children: [String: [FileEntry]], expanded: Set<String>) -> [ExplorerRowItem] {
        var result: [ExplorerRowItem] = []
        for source in sources {
            var startDepth = 0
            if source.showsHeader {
                let header = FileEntry(path: source.root, name: (source.root as NSString).lastPathComponent, isDirectory: true)
                let open = expanded.contains(source.root)
                result.append(ExplorerRowItem(entry: header, depth: 0, root: source.root, isRootHeader: true, isExpanded: open))
                guard open else { continue }
                startDepth = 1
            }
            appendChildren(of: source.root, depth: startDepth, root: source.root, children: children, expanded: expanded, into: &result)
        }
        return result
    }

    /// 深度优先追加某目录的子项(用显式栈,避免深层目录递归)。
    private static func appendChildren(of directory: String, depth: Int, root: String, children: [String: [FileEntry]], expanded: Set<String>, into result: inout [ExplorerRowItem]) {
        // 栈里放「待处理的目录与其层级」;子项逆序入栈以保持原有顺序
        var stack: [(entries: ArraySlice<FileEntry>, depth: Int)] = [((children[directory] ?? [])[...], depth)]
        while var top = stack.popLast() {
            guard let entry = top.entries.popFirst() else { continue }
            stack.append(top)
            let open = entry.isDirectory && expanded.contains(entry.path)
            result.append(ExplorerRowItem(entry: entry, depth: top.depth, root: root, isRootHeader: false, isExpanded: open))
            if open, let sub = children[entry.path], !sub.isEmpty {
                stack.append((sub[...], top.depth + 1))
            }
        }
    }

    /// 由滚动位置计算首个可见行与可见行数(用于只在变化时刷新窗口)。
    /// - Parameters:
    ///   - offset: 内容的垂直滚动偏移(点)
    ///   - viewport: 可视区域高度(点)
    ///   - rowHeight: 固定行高(点,必须大于 0)
    /// - Returns: 首个可见行索引(不小于 0)与可见行数
    public static func viewport(offset: Double, viewport: Double, rowHeight: Double) -> (first: Int, count: Int) {
        guard rowHeight > 0 else { return (0, 0) }
        let first = max(0, Int((max(0, offset) / rowHeight).rounded(.down)))
        let count = max(0, Int((max(0, viewport) / rowHeight).rounded(.up)) + 1)
        return (first, count)
    }

    /// 需要挂载的行区间(可见行上下各加缓冲,并限制在有效范围内)。
    /// - Parameters:
    ///   - first: 首个可见行索引
    ///   - visibleCount: 可见行数
    ///   - total: 总行数
    ///   - overscan: 上下各多挂载的行数
    /// - Returns: 半开区间,总行数为 0 时为空
    public static func window(first: Int, visibleCount: Int, total: Int, overscan: Int = 8) -> Range<Int> {
        guard total > 0 else { return 0..<0 }
        let lower = min(max(0, first - overscan), total)
        let upper = min(total, max(lower, first + visibleCount + overscan))
        return lower..<upper
    }
}
