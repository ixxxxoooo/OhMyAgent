// @author ixxxxoooo
// 中央搜索窗(Hub Search)的纯逻辑:分类、候选、排序与分组。不依赖视图与工作台,便于测试。

import Foundation
import WorkbenchKit

/// 搜索分类(窗口顶部的分段)。
enum HubSegment: String, CaseIterable, Identifiable {
    case all, sessions, projects, files, canvases, actions, settings, themes
    var id: String { rawValue }

    /// 分段标题。
    var title: String {
        switch self {
        case .all: return String(localized: "全部")
        case .sessions: return String(localized: "会话")
        case .projects: return String(localized: "项目")
        case .files: return String(localized: "文件")
        case .canvases: return String(localized: "画布")
        case .actions: return String(localized: "操作")
        case .settings: return String(localized: "设置")
        case .themes: return String(localized: "主题")
        }
    }

    /// 结果分组标题(查询为空时的「最近」语义由引擎覆盖)。
    var groupTitle: String { self == .all ? "" : title }

    /// 切换到下一个/上一个分类(循环)。
    func next(by step: Int) -> HubSegment {
        let all = HubSegment.allCases
        guard let index = all.firstIndex(of: self) else { return self }
        return all[((index + step) % all.count + all.count) % all.count]
    }
}

/// 点击候选后要执行的动作(纯数据,由视图模型执行)。
enum HubAction: Equatable {
    case session(workspace: String, sessionId: String, title: String?)
    case project(path: String)
    case file(root: String, relativePath: String)
    case command(id: String)
    case settings(page: String)
    case theme(id: String)
    case canvas(id: String, title: String)
}

/// 候选图标。
enum HubIcon: Equatable {
    /// 功能图标(Lucide / 语义名)
    case symbol(String)
    /// 彩色文件类型图标
    case file(name: String, isDirectory: Bool)
}

/// 一个可被搜索的候选。
struct HubCandidate: Equatable {
    var id: String
    var segment: HubSegment
    var title: String
    var subtitle: String?
    var trailing: String?
    var icon: HubIcon
    /// 参与模糊匹配的文本(文件用完整相对路径);为空则用标题
    var searchText: String?
    /// 标题未命中时的备选关键词(如设置页的别名)
    var keywords: [String] = []
    var action: HubAction
}

/// 排序后的一行结果。
struct HubItem: Identifiable, Equatable {
    var id: String
    var candidate: HubCandidate
    /// 标题中需要强调的字符位置
    var positions: [Int]
    var title: String { candidate.title }
}

/// 一个分组。
struct HubSection: Identifiable, Equatable {
    var id: String
    var title: String
    var items: [HubItem]
}

/// 搜索引擎:按分类与查询对候选排序、分组。
enum HubSearchEngine {
    /// 分组展示顺序。
    static let order: [HubSegment] = [.sessions, .projects, .files, .canvases, .actions, .settings, .themes]

    /// 排序并分组。
    /// - Parameters:
    ///   - query: 查询(可空)
    ///   - segment: 当前分类
    ///   - candidates: 全部候选(各分类内保持调用方给的先后顺序,如「最近」优先)
    ///   - allLimit: 「全部」分类下每组上限(有查询时)
    ///   - segmentLimit: 单分类上限
    /// - Returns: 分组结果
    static func sections(
        query: String, segment: HubSegment, candidates: [HubCandidate],
        allLimit: Int = 5, segmentLimit: Int = 60
    ) -> [HubSection] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let grouped = Dictionary(grouping: candidates, by: \.segment)
        if segment != .all {
            let items = rank(trimmed, grouped[segment] ?? [], limit: segmentLimit)
            return items.isEmpty ? [] : [HubSection(id: segment.rawValue, title: segment.groupTitle, items: items)]
        }
        if trimmed.isEmpty {
            // 「全部」且无查询:会话、项目、文件限量展示最近项;操作、设置与主题全量列出,
            // 整个结果区可向下滚动,一路看到其他分类的内容。
            var result: [HubSection] = []
            let recent = rank("", grouped[.sessions] ?? [], limit: 6)
            if !recent.isEmpty { result.append(HubSection(id: "recent", title: String(localized: "最近会话"), items: recent)) }
            let projects = rank("", grouped[.projects] ?? [], limit: 5)
            if !projects.isEmpty { result.append(HubSection(id: HubSegment.projects.rawValue, title: HubSegment.projects.title, items: projects)) }
            let files = rank("", grouped[.files] ?? [], limit: 5)
            if !files.isEmpty { result.append(HubSection(id: HubSegment.files.rawValue, title: HubSegment.files.title, items: files)) }
            let canvases = rank("", grouped[.canvases] ?? [], limit: 5)
            if !canvases.isEmpty { result.append(HubSection(id: HubSegment.canvases.rawValue, title: HubSegment.canvases.title, items: canvases)) }
            let actions = rank("", grouped[.actions] ?? [], limit: Int.max)
            if !actions.isEmpty { result.append(HubSection(id: HubSegment.actions.rawValue, title: HubSegment.actions.title, items: actions)) }
            let settings = rank("", grouped[.settings] ?? [], limit: Int.max)
            if !settings.isEmpty { result.append(HubSection(id: HubSegment.settings.rawValue, title: HubSegment.settings.title, items: settings)) }
            let themes = rank("", grouped[.themes] ?? [], limit: Int.max)
            if !themes.isEmpty { result.append(HubSection(id: HubSegment.themes.rawValue, title: HubSegment.themes.title, items: themes)) }
            return result
        }
        return order.compactMap { kind in
            let items = rank(trimmed, grouped[kind] ?? [], limit: allLimit)
            return items.isEmpty ? nil : HubSection(id: kind.rawValue, title: kind.title, items: items)
        }
    }

    /// 对一组候选排序。
    /// - Parameters:
    ///   - query: 已去空白的查询
    ///   - list: 候选
    ///   - limit: 返回上限
    static func rank(_ query: String, _ list: [HubCandidate], limit: Int) -> [HubItem] {
        if query.isEmpty { return list.prefix(limit).map { HubItem(id: $0.id, candidate: $0, positions: []) } }
        var scored: [(item: HubItem, score: Int, index: Int)] = []
        // 纯 ASCII 查询:先用字节子序列预判跳过绝大多数不可能模糊命中的候选(万级文件候选时省掉每个候选的数组分配)
        let prepared = FuzzyMatcher.preparedQuery(query)
        for (index, candidate) in list.enumerated() {
            if let hit = match(query, candidate, prepared: prepared) { scored.append((HubItem(id: candidate.id, candidate: candidate, positions: hit.positions), hit.score, index)) }
        }
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
        return scored.prefix(limit).map(\.item)
    }

    /// 单个候选的匹配:先模糊匹配标题/路径,再退到关键词包含。
    private static func match(_ query: String, _ candidate: HubCandidate, prepared: [UInt8]?) -> (score: Int, positions: [Int])? {
        let text = candidate.searchText ?? candidate.title
        let fuzzyPossible = prepared.flatMap { FuzzyMatcher.mayMatch(preparedQuery: $0, path: text) } ?? true
        if fuzzyPossible, let hit = FuzzyMatcher.match(query: query, path: text) {
            // 高亮位置:优先对标题本身再匹配一次(路径上的贪心匹配可能落在目录里),否则按尾部对齐映射
            let positions: [Int]
            if let own = FuzzyMatcher.match(query: query, path: candidate.title) {
                positions = own.positions
            } else {
                let offset = text.count - candidate.title.count
                positions = text.hasSuffix(candidate.title) ? hit.positions.filter { $0 >= offset }.map { $0 - offset } : []
            }
            return (hit.score + 100, positions)
        }
        let lowered = query.lowercased()
        if candidate.keywords.contains(where: { $0.lowercased().contains(lowered) }) { return (1, []) }
        if let subtitle = candidate.subtitle, subtitle.lowercased().contains(lowered) { return (0, []) }
        return nil
    }
}
