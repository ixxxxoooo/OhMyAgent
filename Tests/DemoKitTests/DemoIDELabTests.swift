// @author ixxxxoooo
// IDE 实验室素材:大文件行数与体积、确定性、多语言样例覆盖首批 tree-sitter 语言。

import Foundation
import Testing
@testable import DemoKit

@Suite("IDE 实验室素材")
struct DemoIDELabTests {
    @Test("Swift 生成:恰好 N 行,以换行结尾,同输入同输出")
    func swiftLinesExact() {
        for count in [1, 11, 12, 13, 100] {
            let text = DemoIDELab.swiftLines(count: count)
            #expect(text.hasSuffix("\n"))
            #expect(text.split(separator: "\n", omittingEmptySubsequences: false).count == count + 1, "行数 \(count)")
        }
        #expect(DemoIDELab.swiftLines(count: 500) == DemoIDELab.swiftLines(count: 500))
        #expect(DemoIDELab.swiftLines(count: 0).isEmpty)
    }

    @Test("大文件:5 万行,体积接近计划测量条件(1.6MB 上下)")
    func bigFileSize() {
        let text = DemoIDELab.swiftLines(count: DemoIDELab.bigLineCount)
        let bytes = text.utf8.count
        #expect(bytes > 1_300_000 && bytes < 1_900_000, "体积 \(bytes)")
        #expect(text.utf8.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 } == DemoIDELab.bigLineCount)
    }

    @Test("超长单行 JSON:存在 20 万字符以上的一行")
    func longLine() {
        let longest = DemoIDELab.longLinesJSON.split(separator: "\n").map(\.count).max() ?? 0
        #expect(longest > 200_000, "最长行 \(longest)")
    }

    @Test("语言样例覆盖首批 tree-sitter 语言,并含一个不支持语言用于回退")
    func languageCoverage() {
        let extensions = Set(DemoIDELab.languageSamples.map { ($0.name as NSString).pathExtension })
        let required: Set = ["swift", "ts", "tsx", "js", "py", "go", "rs", "c", "cpp", "json", "yaml", "toml", "md", "html", "css", "sh"]
        #expect(required.isSubset(of: extensions))
        #expect(extensions.contains("lua"))
        #expect(DemoIDELab.languageSamples.allSatisfy { !$0.text.isEmpty })
        let names = DemoIDELab.languageSamples.map(\.name)
        #expect(Set(names).count == names.count)
    }

    @Test("生成到磁盘:目录结构与文件齐全")
    func buildToDisk() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oma-idelab-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try DemoIDELab.build(in: root)
        let lab = root.appendingPathComponent(DemoIDELab.directoryName)
        for relative in ["README.md", "big/Big50k.swift", "big/Medium2k.swift", "big/LongLines.json", "lang/sample.swift", "lang/sample.sh"] {
            #expect(FileManager.default.fileExists(atPath: lab.appendingPathComponent(relative).path), "缺少 \(relative)")
        }
        let medium = try String(contentsOf: lab.appendingPathComponent("big/Medium2k.swift"), encoding: .utf8)
        #expect(medium.split(separator: "\n", omittingEmptySubsequences: false).count == DemoIDELab.mediumLineCount + 1)
    }
}
