// @author ixxxxoooo
// 输入框内联文件 chip 的纯逻辑:把草稿纯文本切成「文字 / 提及」片段,并在「纯文本坐标」与「文本存储坐标」之间换算光标。
// 草稿(`SessionModel.draft`)始终是带 `@路径` 的纯文本;输入框的文本存储里,每个提及只占 1 个 UTF-16 单元(附件字符)。

import Foundation

/// 输入框内联提及布局。
public enum ComposerMentionLayout {
    /// 文本存储里的一个提及附件。
    public struct Span: Equatable, Sendable {
        /// 附件字符在文本存储中的位置(UTF-16)
        public let storageLocation: Int
        /// 它对应的纯文本记号长度(UTF-16,含 `@` 与引号)
        public let tokenLength: Int

        /// - Parameters:
        ///   - storageLocation: 附件字符在文本存储中的位置
        ///   - tokenLength: 记号的纯文本长度
        public init(storageLocation: Int, tokenLength: Int) {
            self.storageLocation = storageLocation
            self.tokenLength = tokenLength
        }
    }

    /// 草稿切分后的片段。
    public enum Piece: Equatable, Sendable {
        /// 普通文字
        case text(String)
        /// 可显示为 chip 的提及
        case mention(FileMention)
    }

    /// 把草稿切成片段。只有「后面紧跟空白」的提及才会变成 chip,避免用户还在输入路径时被抢先替换。
    /// - Parameters:
    ///   - text: 草稿纯文本
    ///   - workspace: 工作区目录
    ///   - allowTrailingEnd: 位于文本末尾(后面没有字符)的提及是否也变成 chip;外部整体赋值草稿时为 true,用户逐字输入时为 false
    ///   - exists: 路径存在性判断(测试可注入)
    /// - Returns: 按顺序拼回去等于原文的片段
    public static func pieces(
        for text: String,
        workspace: URL,
        allowTrailingEnd: Bool,
        exists: (String) -> Bool? = FileMentions.fileSystemExists
    ) -> [Piece] {
        guard text.contains("@") else { return text.isEmpty ? [] : [.text(text)] }
        var result: [Piece] = []
        var cursor = text.startIndex
        for occurrence in FileMentions.occurrences(in: text, workspace: workspace, exists: exists) {
            let end = occurrence.range.upperBound
            let followedBySpace = end < text.endIndex ? text[end].isWhitespace : allowTrailingEnd
            guard followedBySpace else { continue }
            if cursor < occurrence.range.lowerBound { result.append(.text(String(text[cursor..<occurrence.range.lowerBound]))) }
            result.append(.mention(occurrence.mention))
            cursor = end
        }
        if cursor < text.endIndex { result.append(.text(String(text[cursor...]))) }
        return result
    }

    /// 把片段拼回纯文本。
    /// - Parameter pieces: 片段
    /// - Returns: 草稿纯文本
    public static func plainText(of pieces: [Piece]) -> String {
        pieces.map { piece -> String in
            switch piece {
            case .text(let text): text
            case .mention(let mention): mention.token
            }
        }.joined()
    }

    /// 文本存储坐标 → 纯文本坐标。
    /// - Parameters:
    ///   - storage: 文本存储中的 UTF-16 偏移
    ///   - spans: 提及附件(按位置升序)
    /// - Returns: 纯文本中的 UTF-16 偏移
    public static func plainOffset(storage: Int, spans: [Span]) -> Int {
        var delta = 0
        for span in spans where span.storageLocation < storage { delta += span.tokenLength - 1 }
        return storage + delta
    }

    /// 纯文本坐标 → 文本存储坐标;落在某个记号内部时吸附到该附件之前。
    /// - Parameters:
    ///   - plain: 纯文本中的 UTF-16 偏移
    ///   - spans: 提及附件(按位置升序)
    /// - Returns: 文本存储中的 UTF-16 偏移
    public static func storageOffset(plain: Int, spans: [Span]) -> Int {
        var delta = 0
        for span in spans {
            let plainStart = span.storageLocation + delta
            let plainEnd = plainStart + span.tokenLength
            if plain <= plainStart { break }
            if plain < plainEnd { return span.storageLocation }
            delta += span.tokenLength - 1
        }
        return plain - delta
    }
}
