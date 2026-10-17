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
    /// 「流式整段重解析」次数:未命中且新文本以上一次未命中的文本为前缀(典型是流式输出每批都重解析全文)。
    private(set) static var streamingReparses = 0
    private static var lastMissText = ""

    /// 取解析结果;未命中时解析并写入。
    /// - Parameter text: Markdown 原文
    static func blocks(for text: String) -> [MarkdownBlock] {
        let key = text as NSString
        if let hit = cache.object(forKey: key) {
            hits += 1
            return hit.value
        }
        misses += 1
        if !lastMissText.isEmpty, text.count > lastMissText.count, text.hasPrefix(lastMissText) { streamingReparses += 1 }
        lastMissText = text
        let span = Log.perf.span("Markdown 解析", warnMs: 8, quiet: true, ["chars": "\(text.utf8.count)"])
        let parsed = MarkdownParser.parse(text)
        span.end()
        cache.setObject(Box(parsed), forKey: key, cost: text.utf8.count * 4)
        return parsed
    }

    /// 清空(测试用)。
    static func reset() {
        cache.removeAllObjects()
        hits = 0
        misses = 0
        streamingReparses = 0
        lastMissText = ""
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
