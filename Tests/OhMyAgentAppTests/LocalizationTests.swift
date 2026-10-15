// @author ygw
import Foundation
import Testing

/// 英文本地化文件的静态校验:语法合法、占位符与中文键一致、译文非空。
@Suite("英文本地化")
struct LocalizationTests {
    /// 读取 `Resources/en.lproj/Localizable.strings` 为字典。
    private func loadStrings() throws -> [String: String] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("Resources/en.lproj/Localizable.strings")
        let dict = NSDictionary(contentsOf: url) as? [String: String]
        return try #require(dict, "Localizable.strings 无法解析")
    }

    /// 统计字符串中的格式占位符(`%@`、`%lld`、`%d`、`%f` 等),忽略 `%%`。
    private func placeholders(_ text: String) -> [String] {
        let pattern = #"%(?:\d+\$)?(?:lld|ld|@|d|\.\d+f|f)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]) }
        }
    }

    @Test("文件可解析且译文非空")
    func parsesAndNonEmpty() throws {
        let strings = try loadStrings()
        #expect(strings.count > 300)
        let empty = strings.filter { $0.value.trimmingCharacters(in: .whitespaces).isEmpty }.keys
        #expect(empty.isEmpty, "译文为空:\(empty.sorted())")
    }

    @Test("译文与中文键的占位符数量一致")
    func placeholdersMatch() throws {
        let strings = try loadStrings()
        let bad = strings.filter { placeholders($0.key).count != placeholders($0.value).count }.keys
        #expect(bad.isEmpty, "占位符数量不一致:\(bad.sorted())")
    }
}
