// @author ixxxxoooo
// 行内 Markdown 解析缓存:表格单元格、列表项等在每次 body 都会重新 `AttributedString(markdown:)`,
// 而同一原文的解析结果恒定(与主题无关,链接配色在取出后再套),按原文缓存即可。

import Foundation
import os

/// 行内 Markdown 的解析结果缓存(线程安全,容量由 `NSCache` 自行回收)。
/// 生产代码用全局 `shared`;测试各自创建实例,互不干扰。
final class InlineMarkdownCache: @unchecked Sendable {
    /// 全局实例。
    static let shared = InlineMarkdownCache()

    private final class Box {
        let value: AttributedString?
        init(_ value: AttributedString?) { self.value = value }
    }

    private let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 2000
        return cache
    }()
    private let counter = OSAllocatedUnfairLock(initialState: 0)

    /// 实际解析次数(测试用)。
    var parseCount: Int { counter.withLock { $0 } }

    /// 解析行内 Markdown(保留空白);带缓存。
    /// - Parameter source: 原文
    /// - Returns: 解析结果;解析失败返回 nil(调用方回退为纯文本)
    func parsed(_ source: String) -> AttributedString? {
        let key = source as NSString
        if let hit = cache.object(forKey: key) { return hit.value }
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let value = try? AttributedString(markdown: source, options: options)
        counter.withLock { $0 += 1 }
        cache.setObject(Box(value), forKey: key)
        return value
    }
}
