// @author ixxxxoooo
// 代码高亮(只读展示用):聊天代码块、Markdown 预览等把代码转成带语法颜色的 AttributedString。
// 结果按「语言 + 内容」缓存,流式输出与反复重绘不重复扫描。

import AppKit
import DesignSystem
import Foundation
import Synchronization
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

    private static let counters = Mutex((hits: 0, misses: 0))

    /// 缓存命中/未命中累计(诊断用)。
    public static var cacheStats: (hits: Int, misses: Int) { counters.withLock { $0 } }

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
        let themeKey = currentThemeKey()
        let key = cacheKey(code, language: language, themeKey: themeKey)
        if let hit = cache.object(forKey: key) {
            counters.withLock { $0.hits += 1 }
            return hit.value
        }
        // 流式状态里正好是这段文本(流式结束后再次渲染):直接取用并晋升进缓存
        if let state = streamStates.last(where: { $0.language == language && $0.themeKey == themeKey && $0.code == code }) {
            counters.withLock { $0.hits += 1 }
            cache.setObject(Box(state.full), forKey: key, cost: code.utf16.count * 4)
            return state.full
        }
        counters.withLock { $0.misses += 1 }
        guard streamable(language) else {
            let result = build(code, language: language)
            cache.setObject(Box(result), forKey: key, cost: code.utf16.count * 4)
            return result
        }
        let built = buildStreaming(code, language: language, themeKey: themeKey)
        // 文本在持续增长(新文本完整延伸了上一次的文本)时不写缓存:每一批都写会让大量中间版本挤掉有用条目;
        // 这些中间结果由流式状态持有,结束后精确命中时再晋升(见上),被淘汰的状态也会落进缓存
        if !built.growing { cache.setObject(Box(built.result), forKey: key, cost: code.utf16.count * 4) }
        return built.result
    }

    /// 缓存键:主题、语言与内容哈希/长度。
    private static func cacheKey(_ code: String, language: SyntaxLanguage, themeKey: String) -> NSString {
        "\(themeKey)#\(language.rawValue)#\(code.hashValue)#\(code.utf16.count)" as NSString
    }

    /// 流式追加段:相对上一次稳定边界之后的着色文本,供文本视图只替换尾部。
    public struct StreamSegment {
        /// 从 `from` 起到文本末尾的着色文本
        public let text: AttributedString
        /// 本次的稳定边界(UTF-16 偏移):边界之前的着色已是最终结果
        public let stableUnits: Int
    }

    /// 取「上一次稳定边界之后」的着色段。仅当最近一次高亮的正是 `code`、且那次构建的起点恰为 `previousStable` 时可用,
    /// 否则返回 nil(调用方退回整段构建)。
    /// - Parameters:
    ///   - code: 当前完整源码(须先调用过 `attributed`)
    ///   - language: 语言
    ///   - previousStable: 调用方上一次拿到的稳定边界
    /// - Returns: 追加段;不可用时 nil
    public static func streamingSegment(_ code: String, language: SyntaxLanguage, from previousStable: Int) -> StreamSegment? {
        let themeKey = currentThemeKey()
        guard let state = streamStates.last(where: { $0.language == language && $0.themeKey == themeKey && $0.code == code }),
              state.base == previousStable else { return nil }
        return StreamSegment(text: state.segment, stableUnits: state.stableUnits)
    }

    /// 当前文本对应的稳定边界(没有流式状态时为 0)。
    public static func stableUnits(_ code: String, language: SyntaxLanguage) -> Int {
        let themeKey = currentThemeKey()
        return streamStates.last(where: { $0.language == language && $0.themeKey == themeKey && $0.code == code })?.stableUnits ?? 0
    }

    /// 按围栏标签生成(`ts`、`sh` 等别名)。
    public static func attributed(_ code: String, fence: String?) -> AttributedString {
        attributed(code, language: SyntaxLanguage.fromFence(fence))
    }

    /// 清空缓存(外观或字号变化时按需调用)。
    public static func clearCache() {
        cache.removeAllObjects()
        colorCache = nil
    }

    /// 当前主题的缓存键:主题 id、明暗、代码高亮偏好与主题修订号(强调色等变化)。
    private static func currentThemeKey() -> String {
        "\(ThemeRuntime.package.id)#\(ThemeRuntime.systemIsDark)#\(SyntaxPrefs.cacheKey)#\(ThemeTracker.shared.revision)"
    }

    /// 各片段类型的前景色缓存:`EditorTheme.default` 每次都会重新生成一整套动态色,
    /// 流式时每一批都生成一次很浪费,按主题键缓存一份 SwiftUI `Color`。
    private static var colorCache: (key: String, colors: [SyntaxKind: Color])?

    /// 取当前主题的片段颜色表(同主题键命中缓存)。
    private static func syntaxColors() -> [SyntaxKind: Color] {
        let key = currentThemeKey()
        if let cached = colorCache, cached.key == key { return cached.colors }
        let colors = EditorTheme.default.colors.mapValues { Color(nsColor: $0) }
        colorCache = (key, colors)
        return colors
    }

    /// 全量构建(无增量状态)。
    static func build(_ code: String, language: SyntaxLanguage) -> AttributedString {
        let spans = SimpleLexer.lex(code, language: language)
        guard !spans.isEmpty else { return AttributedString(code) }
        let units = Array(code.utf16)
        var result = AttributedString()
        append(&result, units: units, spans: spans, from: 0, to: units.count)
        return result
    }

    /// 把 `units[from..<to]` 按片段着色后追加到 `result`;片段必须完全落在该区间内。
    private static func append(_ result: inout AttributedString, units: [UInt16], spans: [SyntaxSpan], from: Int, to: Int) {
        let colors = syntaxColors()
        var cursor = from
        func slice(_ lower: Int, _ upper: Int) -> String { String(decoding: units[lower..<upper], as: UTF16.self) }
        for span in spans where span.location >= cursor && span.location + span.length <= to {
            if span.location > cursor { result.append(AttributedString(slice(cursor, span.location))) }
            var piece = AttributedString(slice(span.location, span.location + span.length))
            if let color = colors[span.kind] { piece.foregroundColor = color }
            result.append(piece)
            cursor = span.location + span.length
        }
        if cursor < to { result.append(AttributedString(slice(cursor, to))) }
    }

    // MARK: - 流式增量

    /// 流式增量状态:`stable` 是文本前 `stableUnits` 个 UTF-16 单元的最终着色结果。
    /// 稳定边界取在某一行行首、且没有任何词法片段跨过它(通用词法器在行首、无跨行片段时是无状态的,
    /// 所以从边界继续扫描与全量扫描结果一致)。下一批只需重扫边界之后的文本。
    private struct StreamState {
        var code: String
        var themeKey: String
        var language: SyntaxLanguage
        var stable: AttributedString
        var stableUnits: Int
        /// 完整着色结果(= stable + 未稳定尾部)
        var full: AttributedString
        /// 本次构建的起点(上一次的稳定边界)
        var base: Int
        /// 起点之后的着色文本(新稳定的部分 + 未稳定尾部)
        var segment: AttributedString
    }

    /// 流式构建的结果。
    private struct StreamBuild {
        let result: AttributedString
        /// 新文本是否完整延伸了某个流式状态的旧文本(真正的「增长」)
        let growing: Bool
    }

    /// 最近的流式状态(同时流式输出的代码块不会超过几个,超出按先进先出淘汰)。
    private static var streamStates: [StreamState] = []
    private static let maxStreamStates = 4
    /// 命中流式续扫的次数(测试与诊断用)
    public private(set) static var incrementalBuilds = 0

    /// 通用词法器之外的语言(HTML 的标签内、CSS 的花括号深度是跨行状态)不做增量。
    private static func streamable(_ language: SyntaxLanguage) -> Bool {
        language != .plain && language != .html && language != .css
    }

    /// 带续扫的构建:新文本是某个已有状态的扩展时,只重扫稳定边界之后的部分。
    private static func buildStreaming(_ code: String, language: SyntaxLanguage, themeKey: String) -> StreamBuild {
        let units = Array(code.utf16)
        var base = 0
        var stable = AttributedString()
        var slot: Int?
        var growing = false
        for (index, state) in streamStates.enumerated().reversed()
        where state.language == language && state.themeKey == themeKey && state.stableUnits <= units.count
            && code.utf16.prefix(state.stableUnits).elementsEqual(state.code.utf16.prefix(state.stableUnits)) {
            base = state.stableUnits
            stable = state.stable
            slot = index
            growing = code.utf16.count > state.code.utf16.count && code.utf8.starts(with: state.code.utf8)
            break
        }
        if slot != nil { incrementalBuilds += 1 }
        // 只扫描稳定边界之后的文本,片段位置平移回全文坐标
        let suffix = String(decoding: units[base...], as: UTF16.self)
        let spans = SimpleLexer.lex(suffix, language: language).map {
            SyntaxSpan(location: $0.location + base, length: $0.length, kind: $0.kind)
        }
        let boundary = stableBoundary(units: units, spans: spans, from: base)
        // 起点之后分两段构建:新稳定的部分(并入 head)与未稳定尾部
        var middle = AttributedString()
        append(&middle, units: units, spans: spans, from: base, to: boundary)
        var tail = AttributedString()
        append(&tail, units: units, spans: spans, from: boundary, to: units.count)
        var head = stable
        head.append(middle)
        var result = head
        result.append(tail)
        var segment = middle
        segment.append(tail)
        let state = StreamState(code: code, themeKey: themeKey, language: language, stable: head, stableUnits: boundary,
                                full: result, base: base, segment: segment)
        if let slot {
            // 槽位被另一段不相干的文本接管(只共享了前缀):旧文本的最终结果落进缓存
            if !growing {
                let old = streamStates[slot]
                cache.setObject(Box(old.full), forKey: cacheKey(old.code, language: old.language, themeKey: old.themeKey),
                                cost: old.code.utf16.count * 4)
            }
            streamStates[slot] = state
        } else {
            streamStates.append(state)
            if streamStates.count > maxStreamStates {
                // 被淘汰的状态落进缓存:它可能是一段已经结束的流式输出,之后还会被渲染
                for evicted in streamStates.prefix(streamStates.count - maxStreamStates) {
                    cache.setObject(Box(evicted.full), forKey: cacheKey(evicted.code, language: evicted.language, themeKey: evicted.themeKey),
                                    cost: evicted.code.utf16.count * 4)
                }
                streamStates.removeFirst(streamStates.count - maxStreamStates)
            }
        }
        return StreamBuild(result: result, growing: growing)
    }

    /// 找新的稳定边界:最后一个行首(`\n` 之后),且没有片段跨过它;找不到则保持 `from`。
    /// 最后一行(可能还在增长)永远不在稳定部分里。
    private static func stableBoundary(units: [UInt16], spans: [SyntaxSpan], from: Int) -> Int {
        var position = units.count - 1
        var attempts = 0
        while position > from, attempts < 16 {
            if units[position - 1] == 0x0A {
                let crossing = spans.contains { $0.location < position && position < $0.location + $0.length }
                if !crossing { return position }
                attempts += 1
            }
            position -= 1
        }
        return from
    }

    /// 清空流式状态(测试用)。
    public static func resetStreaming() {
        streamStates.removeAll()
        incrementalBuilds = 0
    }
}
