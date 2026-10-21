// @author ixxxxoooo
// 设置页保活:最近访问的静态设置页保持挂载,切回时不必重建 AppKit 控件与重新测量整页布局。
// 进入时才加载数据的页面(提供商、映射、扩展、用量、诊断等)不参与保活,每次进入仍重建以拿到最新数据。

/// 设置页保活状态(纯值类型,便于测试)。
struct SettingsKeepAlive: Equatable {
    /// 保活页数上限(含当前页)。
    let limit: Int
    /// 保活中的页面,最近访问的在前。
    private(set) var recent: [SettingsPage] = []

    /// - Parameter limit: 保活页数上限(至少 1)
    init(limit: Int = 6) {
        self.limit = max(1, limit)
    }

    /// 进入时会加载数据、保活会导致数据过期的页面。
    static let reloadOnShow: Set<SettingsPage> = [
        .providers, .modelMapping, .agentExtensions, .mcp, .skills, .subagents,
        .hooks, .plugins, .memory, .usage, .advanced, .diagnostics,
    ]

    /// 记录一次访问:可保活的页面移到最前并按上限裁剪。
    /// - Parameter page: 被访问的页面
    mutating func visit(_ page: SettingsPage) {
        guard !Self.reloadOnShow.contains(page) else { return }
        recent.removeAll { $0 == page }
        recent.insert(page, at: 0)
        if recent.count > limit { recent.removeLast(recent.count - limit) }
    }

    /// 需要挂载的页面:保活页 + 当前页,按固定顺序排列(保证视图身份与层级稳定)。
    /// - Parameter current: 当前显示的页面
    /// - Returns: 挂载顺序的页面列表
    func mounted(current: SettingsPage) -> [SettingsPage] {
        let set = Set(recent).union([current])
        return SettingsPage.allCases.filter { set.contains($0) }
    }
}
