// @author ixxxxoooo
// 渲染缓存:Markdown 解析结果、Mermaid 场景按内容缓存,标签/会话切换或视图被重新挂载时直接命中,不再重算;
// 以及随标签活动状态暂停的定时器视图(后台保活标签不空转刷新)。

import ChatKit
import DesignSystem
import MermaidKit
import OMLog
import SwiftUI

/// NSCache 需要引用类型作为值。
private final class Box<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// Markdown 块级解析缓存(按全文)。
@MainActor
enum MarkdownCache {
    private static let cache: NSCache<NSString, Box<[MarkdownBlock]>> = {
        let cache = NSCache<NSString, Box<[MarkdownBlock]>>()
        cache.countLimit = 400
        cache.totalCostLimit = 24 * 1024 * 1024
        return cache
    }()
    /// 命中/未命中统计(测试与诊断用)
    private(set) static var hits = 0
    private(set) static var misses = 0
    /// 「流式整段重解析」次数:新文本是上一次未命中文本的扩展,却没能复用续解析状态而整段重解析
    /// (增量解析生效后应接近 0;持续增长说明续解析被打断,如状态被挤出)。
    private(set) static var streamingReparses = 0
    /// 增量解析次数(只重解析末尾两个块)。
    private(set) static var incrementalParses = 0
    private static var lastMissText = ""
    /// 最近的续解析状态(同时流式输出的消息不会超过几条,超出按先进先出淘汰)。
    private static var states: [MarkdownParseState] = []
    private static let maxStates = 6

    /// 取解析结果;未命中时解析并写入。
    /// - Parameters:
    ///   - text: Markdown 原文
    ///   - streaming: 文本是否仍在流式增长。流式中间态不写入全文缓存(每一批文本都不同,写进去只会挤掉有用的条目),
    ///     只更新续解析状态;流式结束后的最终文本再正常入缓存
    static func blocks(for text: String, streaming: Bool = false) -> [MarkdownBlock] {
        let key = text as NSString
        if let hit = cache.object(forKey: key) {
            hits += 1
            return hit.value
        }
        misses += 1
        let span = Log.perf.span("Markdown 解析", warnMs: 8, quiet: true, ["chars": "\(text.utf8.count)", "streaming": "\(streaming)"])
        let baseIndex = states.lastIndex { Self.extends(text, $0.text) }
        let state = MarkdownParser.parseState(text, continuing: baseIndex.map { states[$0] })
        span.end()
        if let baseIndex {
            incrementalParses += 1
            states[baseIndex] = state
        } else {
            if !lastMissText.isEmpty, text.utf8.count > lastMissText.utf8.count, text.hasPrefix(lastMissText) { streamingReparses += 1 }
            states.append(state)
            if states.count > maxStates { states.removeFirst(states.count - maxStates) }
        }
        lastMissText = text
        if !streaming { cache.setObject(Box(state.blocks), forKey: key, cost: text.utf8.count * 4) }
        return state.blocks
    }

    /// 廉价预判 `text` 是否可能是 `base` 的扩展:长度不小于且开头 64 字节一致(完整前缀校验在解析器里做)。
    private static func extends(_ text: String, _ base: String) -> Bool {
        let probe = min(64, base.utf8.count)
        return text.utf8.count >= base.utf8.count && text.utf8.prefix(probe).elementsEqual(base.utf8.prefix(probe))
    }

    /// 清空(测试用)。
    static func reset() {
        cache.removeAllObjects()
        hits = 0
        misses = 0
        streamingReparses = 0
        incrementalParses = 0
        lastMissText = ""
        states.removeAll()
    }
}

/// Mermaid 渲染结果缓存(按源码;场景与明暗无关,明暗在绘制时决定)。
@MainActor
enum MermaidSceneCache {
    private static let cache: NSCache<NSString, Box<MermaidResult>> = {
        let cache = NSCache<NSString, Box<MermaidResult>>()
        cache.countLimit = 120
        return cache
    }()

    /// 同步读取已缓存的结果(视图初始状态用,避免重新挂载时先空白再出图)。
    static func cached(_ source: String) -> MermaidResult? { cache.object(forKey: source as NSString)?.value }

    /// 写入缓存。
    static func store(_ result: MermaidResult, for source: String) {
        cache.setObject(Box(result), forKey: source as NSString)
    }
}

/// 只在所属标签处于活动状态时按间隔刷新的时间线;后台保活的标签降到极低频,不再每秒/每帧重绘。
struct ActiveTimeline<Content: View>: View {
    /// 活动时的刷新间隔(秒)
    let interval: Double
    /// 起点(用于对齐帧)
    var start: Date = .now
    @ViewBuilder let content: (Date) -> Content
    @Environment(\.tabIsActive) private var isActive

    var body: some View {
        TimelineView(.periodic(from: start, by: isActive ? interval : 600)) { context in
            content(context.date)
        }
    }
}
