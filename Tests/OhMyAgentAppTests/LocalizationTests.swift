// @author ixxxxoooo
// 中英文本地化资源的静态校验:语法合法、占位符一致、译文非空、中英文键同步、Info.plist 配置正确。

import Foundation
import Testing

/// 本地化资源静态校验(读取仓库内 `Resources/`,不依赖运行时语言)。
@Suite("中英文本地化")
struct LocalizationTests {
    /// 仓库根目录。
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// 读取某语言的 `.strings` 文件为字典。
    /// - Parameters:
    ///   - language: 语言目录名(如 `en`、`zh-Hans`)
    ///   - table: 表名(`Localizable` 或 `InfoPlist`)
    private func loadStrings(_ language: String, table: String = "Localizable") throws -> [String: String] {
        let url = root.appendingPathComponent("Resources/\(language).lproj/\(table).strings")
        let dict = NSDictionary(contentsOf: url) as? [String: String]
        return try #require(dict, "\(language).lproj/\(table).strings 无法解析")
    }

    /// 统计字符串中的格式占位符(`%@`、`%lld`、`%d`、`%f` 等),忽略 `%%`。
    private func placeholders(_ text: String) -> [String] {
        let pattern = #"%(?:\d+\$)?(?:lld|ld|@|d|\.\d+f|f)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            // 去掉位置序号(`%2$lld` 与 `%lld` 视为同一种类),只比较类型
            Range(match.range, in: text).map { String(text[$0]).replacingOccurrences(of: #"\d+\$"#, with: "", options: .regularExpression) }
        }
    }

    @Test("文件可解析且译文非空")
    func parsesAndNonEmpty() throws {
        let strings = try loadStrings("en")
        #expect(strings.count > 1000)
        let empty = strings.filter { $0.value.trimmingCharacters(in: .whitespaces).isEmpty }.keys
        #expect(empty.isEmpty, "译文为空:\(empty.sorted())")
    }

    @Test("译文与中文键的占位符数量一致")
    func placeholdersMatch() throws {
        let strings = try loadStrings("en")
        let bad = strings.filter { placeholders($0.key).count != placeholders($0.value).count }.keys
        #expect(bad.isEmpty, "占位符数量不一致:\(bad.sorted())")
    }

    @Test("译文与中文键的占位符种类一致")
    func placeholderKindsMatch() throws {
        let strings = try loadStrings("en")
        let bad = strings.filter { placeholders($0.key).sorted() != placeholders($0.value).sorted() }.keys
        #expect(bad.isEmpty, "占位符种类不一致(%@ / %lld 混用会导致运行时崩溃或乱码):\(bad.sorted())")
    }

    @Test("英文译文不应残留中文(文件名等专有名词除外)")
    func englishHasNoHan() throws {
        let strings = try loadStrings("en")
        let han = try Regex("[\u{4e00}-\u{9fff}]")
        let bad = strings.filter { $0.value.replacingOccurrences(of: "开发进度.md", with: "").contains(han) }.keys
        #expect(bad.isEmpty, "译文里仍有中文:\(bad.sorted())")
    }

    @Test("简体中文资源与英文键一一对应且值等于键")
    func zhHansMatchesEnglishKeys() throws {
        let en = try loadStrings("en")
        let zh = try loadStrings("zh-Hans")
        #expect(Set(en.keys) == Set(zh.keys), "运行 Scripts/sync-zh-strings.py 同步")
        let bad = zh.filter { $0.key != $0.value }.keys
        #expect(bad.isEmpty, "中文资源的值必须等于键:\(bad.sorted())")
    }

    @Test("InfoPlist 本地化包含应用名与版权")
    func infoPlistStrings() throws {
        for language in ["en", "zh-Hans"] {
            let strings = try loadStrings(language, table: "InfoPlist")
            #expect(strings["CFBundleDisplayName"] == "OhMyAgent")
            #expect(strings["NSHumanReadableCopyright"]?.contains("ixxxxoooo") == true)
        }
    }

    @Test("Info.plist:Bundle ID、开发区域与语言列表")
    func infoPlistConfiguration() throws {
        let url = root.appendingPathComponent("Resources/Info.plist")
        let info = try #require(NSDictionary(contentsOf: url) as? [String: Any], "Info.plist 无法解析")
        #expect(info["CFBundleIdentifier"] as? String == "com.ixxxxoooo.OhMyAgent")
        #expect(info["CFBundleDevelopmentRegion"] as? String == "en")
        let languages = info["CFBundleLocalizations"] as? [String] ?? []
        #expect(Set(languages) == ["en", "zh-Hans"])
    }
}
