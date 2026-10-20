// @author ixxxxoooo
// Plan 路径链接化测试:存在的文件才链接、行号后缀、围栏代码块内不改写、往返解析。

import Foundation
import Testing
@testable import ChatKit

@Suite("Plan 路径链接")
struct PlanPathLinkerTests {
    private let root = "/proj"
    private let existing: Set<String> = ["/proj/Sources/A.swift", "/abs/B.md"]

    private func link(_ text: String) -> String {
        PlanPathLinker.link(text, root: root) { existing.contains($0) }
    }

    @Test("相对路径与绝对路径都改写成链接,带行号后缀")
    func linksExistingFiles() throws {
        let out = link("修改 `Sources/A.swift:12` 与 `/abs/B.md`。")
        #expect(out.contains("[Sources/A.swift:12](oma-file://open?"))
        #expect(out.contains("[/abs/B.md](oma-file://open?"))
        let match = try #require(out.range(of: "oma-file://[^)]+", options: .regularExpression))
        let parsed = try #require(PlanPathLinker.parse(link: URL(string: String(out[match]))!))
        #expect(parsed.0 == "/proj/Sources/A.swift" && parsed.1 == 12)
    }

    @Test("不存在的路径、普通代码与链接保持原样")
    func ignoresOthers() {
        let text = "运行 `swift build`,见 `Missing.swift` 与 `https://a.b/c.md`"
        #expect(link(text) == text)
    }

    @Test("围栏代码块里的内容不改写")
    func skipsFences() {
        let text = "```\n`Sources/A.swift`\n```"
        #expect(link(text) == text)
    }

    @Test("非本 scheme 的链接不解析")
    func parseOtherScheme() {
        #expect(PlanPathLinker.parse(link: URL(string: "https://a.b")!) == nil)
    }
}
