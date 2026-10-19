// @author ixxxxoooo
// 行内 Markdown 解析缓存:表格单元格、列表项等在每次 body 都会重新 `AttributedString(markdown:)`,
// 而同一原文的解析结果恒定(与主题无关,链接配色在取出后再套),按原文缓存即可。

import Foundation

/// 行内 Markdown 的解析结果缓存(线程安全,容量由 `NSCache` 自行回收)。
enum InlineMarkdownCache {
    private final class Box: @unchecked Sendable {
        let value: AttributedString?
        init(_ value: AttributedString?) { self.value = value }
    }

    nonisolated(unsafe) private static let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 2000
        return cache
    }()

    /// 实际解析次数(测试用)。
    nonisolated(unsafe) private(set) static var parseCount = 0

    /// 解析行内 Markdown(保留空白);带缓存。
    /// - Parameter source: 原文
    /// - Returns: 解析结果;解析失败返回 nil(调用方回退为纯文本)
    static func parsed(_ source: String) -> AttributedString? {
        let key = source as NSString
        if let hit = cache.object(forKey: key) { return hit.value }
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let value = try? AttributedString(markdown: source, options: options)
        parseCount += 1
        cache.setObject(Box(value), forKey: key)
        return value
    }

    /// 清空缓存(测试用)。
    static func reset() {
        cache.removeAllObjects()
        parseCount = 0
    }
}
