// @author ixxxxoooo
// 编辑器内查找的纯逻辑(可单测):选项、正则编译、匹配、前后跳转与替换文本生成。

import Foundation

/// 查找选项。
public struct EditorFindOptions: Equatable, Sendable {
    /// 区分大小写
    public var caseSensitive: Bool
    /// 全词匹配
    public var wholeWord: Bool
    /// 正则表达式
    public var regex: Bool

    public init(caseSensitive: Bool = false, wholeWord: Bool = false, regex: Bool = false) {
        self.caseSensitive = caseSensitive
        self.wholeWord = wholeWord
        self.regex = regex
    }
}

/// 查找引擎(无状态)。
public enum EditorFindEngine {
    /// 单次最多收集的匹配数,避免超大文件上的海量结果拖垮界面。
    public static let maxMatches = 50_000

    /// 把查询词与选项编译成正则。
    /// - Parameters:
    ///   - query: 查询词(空串返回 nil)
    ///   - options: 查找选项
    /// - Returns: 编译结果;查询为空或正则非法时为 nil
    public static func compile(query: String, options: EditorFindOptions) -> NSRegularExpression? {
        guard !query.isEmpty else { return nil }
        var pattern = options.regex ? query : NSRegularExpression.escapedPattern(for: query)
        if options.wholeWord { pattern = "\\b(?:" + pattern + ")\\b" }
        var flags: NSRegularExpression.Options = options.regex ? [.anchorsMatchLines] : []
        if !options.caseSensitive { flags.insert(.caseInsensitive) }
        return try? NSRegularExpression(pattern: pattern, options: flags)
    }

    /// 在文本中收集全部非空匹配(最多 `maxMatches` 个)。
    /// - Parameters:
    ///   - regex: 已编译的正则
    ///   - text: 文本
    /// - Returns: 按位置升序的匹配结果
    public static func matches(of regex: NSRegularExpression, in text: String) -> [NSTextCheckingResult] {
        var results: [NSTextCheckingResult] = []
        regex.enumerateMatches(in: text, options: [], range: NSRange(location: 0, length: text.utf16.count)) { result, _, stop in
            guard let result, result.range.length > 0 else { return }
            results.append(result)
            if results.count >= maxMatches { stop.pointee = true }
        }
        return results
    }

    /// 从某个位置出发找到下一个/上一个匹配的下标(到头后回绕)。
    /// - Parameters:
    ///   - ranges: 升序的匹配范围
    ///   - location: 起点(向前:取起点及其之后的第一个;向后:取起点之前的最后一个)
    ///   - forward: 方向
    /// - Returns: 下标;没有匹配时为 nil
    public static func index(in ranges: [NSRange], from location: Int, forward: Bool) -> Int? {
        guard !ranges.isEmpty else { return nil }
        if forward { return ranges.firstIndex { $0.location >= location } ?? 0 }
        return ranges.lastIndex { $0.location < location } ?? ranges.count - 1
    }

    /// 生成某个匹配的替换文本(正则模式支持 `$1` 等捕获组模板)。
    /// - Parameters:
    ///   - result: 匹配结果
    ///   - regex: 产生该结果的正则
    ///   - text: 被搜索的文本
    ///   - template: 用户输入的替换内容
    ///   - options: 查找选项(非正则模式下原样使用模板)
    /// - Returns: 替换文本
    public static func replacement(for result: NSTextCheckingResult, regex: NSRegularExpression, in text: String, template: String, options: EditorFindOptions) -> String {
        options.regex ? regex.replacementString(for: result, in: text, offset: 0, template: template) : template
    }
}
