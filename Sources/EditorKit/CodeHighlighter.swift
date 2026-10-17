// @author ixxxxoooo
// 代码高亮(只读展示用):聊天代码块、Markdown 预览等把代码转成带语法颜色的 AttributedString。
// 结果按「语言 + 内容」缓存,流式输出与反复重绘不重复扫描。

import AppKit
import DesignSystem
import Foundation
import SwiftUI

/// 代码高亮器。
@MainActor
public enum CodeHighlighter {
    /// 超过该字符数的代码不高亮(保持流畅)。
    public static let maxCharacters = 80_000

    private final class Box: NSObject {
        let value: AttributedString
        init(_ value: AttributedString) { self.value = value }
    }

    private static let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 400
        cache.totalCostLimit = 8_000_000
        return cache
    }()

    /// 生成带语法颜色的文本。
    /// - Parameters:
    ///   - code: 源码
    ///   - language: 语言;`.plain` 或超长文本返回无样式文本
    /// - Returns: 带前景色的 AttributedString(字体由调用方的 `.font` 决定)
    public static func attributed(_ code: String, language: SyntaxLanguage) -> AttributedString {
        guard language != .plain, !code.isEmpty, code.utf16.count <= maxCharacters else { return AttributedString(code) }
        // 缓存键含主题 id 与明暗:切换主题后同一段代码立即以新配色重新生成
        _ = ThemeRuntime.palette
        let key = "\(ThemeRuntime.package.id)#\(ThemeRuntime.systemIsDark)#\(SyntaxPrefs.cacheKey)#\(language.rawValue)#\(code.hashValue)#\(code.utf16.count)" as NSString
        if let hit = cache.object(forKey: key) { return hit.value }
        let result = build(code, language: language)
        cache.setObject(Box(result), forKey: key, cost: code.utf16.count * 4)
        return result
    }

    /// 按围栏标签生成(`ts`、`sh` 等别名)。
    public static func attributed(_ code: String, fence: String?) -> AttributedString {
        attributed(code, language: SyntaxLanguage.fromFence(fence))
    }

    /// 清空缓存(外观或字号变化时按需调用)。
    public static func clearCache() { cache.removeAllObjects() }

    private static func build(_ code: String, language: SyntaxLanguage) -> AttributedString {
        let spans = SimpleLexer.lex(code, language: language)
        guard !spans.isEmpty else { return AttributedString(code) }
        let units = Array(code.utf16)
        let theme = EditorTheme.default
        var result = AttributedString()
        var cursor = 0
        func slice(_ from: Int, _ to: Int) -> String { String(decoding: units[from..<to], as: UTF16.self) }
        for span in spans where span.location >= cursor && span.location + span.length <= units.count {
            if span.location > cursor { result.append(AttributedString(slice(cursor, span.location))) }
            var piece = AttributedString(slice(span.location, span.location + span.length))
            if let color = theme.colors[span.kind] { piece.foregroundColor = Color(nsColor: color) }
            result.append(piece)
            cursor = span.location + span.length
        }
        if cursor < units.count { result.append(AttributedString(slice(cursor, units.count))) }
        return result
    }
}
