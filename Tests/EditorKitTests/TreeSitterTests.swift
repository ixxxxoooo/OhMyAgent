// @author ixxxxoooo
// tree-sitter 高亮(I5):各语言查询可编译、UTF-16 偏移正确、增量重解析、谓词、词法回退。

import Foundation
import Testing
@testable import EditorKit

/// 取 `kind` 类别里被高亮的文本集合。
private func texts(_ spans: [SyntaxSpan], _ kind: SyntaxKind, in source: String) -> [String] {
    let ns = source as NSString
    return spans.filter { $0.kind == kind }.map { ns.substring(with: NSRange(location: $0.location, length: $0.length)) }
}

@Suite("tree-sitter 高亮")
struct TreeSitterHighlightTests {
    static let samples: [SyntaxLanguage: String] = [
        .swift: "import Foundation\n// 注释\nstruct A { let x: Int = 42\n func f() -> String { \"hi\" } }\n",
        .javascript: "// c\nconst x = 42;\nfunction f(a) { return \"s\" + a; }\nclass B extends A {}\n",
        .typescript: "// c\ninterface I { a: number }\nconst x: string = \"s\";\nfunction f(a: I): void { return; }\n",
        .python: "# c\ndef f(a):\n    return \"s\" + str(42)\nclass B(A):\n    pass\n",
        .json: "{\"a\": 1, \"b\": [true, null], \"c\": \"s\"}\n",
        .rust: "// c\nfn main() { let x: i32 = 42; println!(\"hi\"); }\nstruct S;\n",
        .go: "package main\n// c\nfunc f(a int) string { return \"s\" }\ntype T struct{}\n",
        .css: "/* c */\na { color: red; margin: 0 }\n@media (min-width: 1px) { b { top: 1px } }\n",
        .html: "<!-- c -->\n<div class=\"a\">text</div>\n",
    ]

    @Test("每种语言的查询都能编译并产出高亮片段")
    func allLanguages() async {
        for (language, source) in Self.samples {
            let engine = HighlightEngine()
            await engine.rebuild(text: source, language: language)
            #expect(await engine.usesTreeSitter, "\(language) 应使用 tree-sitter")
            let spans = await engine.spans(in: NSRange(location: 0, length: (source as NSString).length))
            #expect(!spans.isEmpty, "\(language) 没有高亮片段")
            #expect(!(await engine.treeHasErrors), "\(language) 样例不应有语法错误")
        }
    }

    @Test("Swift:关键字/字符串/注释/数字/类型归类正确")
    func swiftKinds() async {
        let source = Self.samples[.swift] ?? ""
        let engine = HighlightEngine()
        await engine.rebuild(text: source, language: .swift)
        let spans = await engine.spans(in: NSRange(location: 0, length: (source as NSString).length))
        #expect(texts(spans, .keyword, in: source).contains("struct"))
        #expect(texts(spans, .keyword, in: source).contains("func"))
        #expect(texts(spans, .comment, in: source).contains { $0.contains("注释") })
        #expect(texts(spans, .number, in: source).contains("42"))
        #expect(texts(spans, .type, in: source).contains("Int"))
        #expect(texts(spans, .string, in: source).contains { $0.contains("hi") })
    }

    @Test("中文与表情之后的偏移按 UTF-16 计算")
    func utf16Offsets() async {
        let source = "// 你好😀世界\nlet name = \"x\"\n"
        let engine = HighlightEngine()
        await engine.rebuild(text: source, language: .swift)
        let spans = await engine.spans(in: NSRange(location: 0, length: (source as NSString).length))
        #expect(texts(spans, .keyword, in: source).contains("let"))
        #expect(texts(spans, .string, in: source).contains("x"))
    }

    @Test("编辑后增量重解析,新内容立即反映在高亮里")
    func incremental() async {
        let engine = HighlightEngine()
        var source = "let a = 1\nlet b = 2\n"
        await engine.rebuild(text: source, language: .swift)
        #expect(!(await engine.lastParseWasIncremental))
        source = "let a = 1\nlet b = \"two\"\n"
        await engine.rebuild(text: source, language: .swift)
        #expect(await engine.lastParseWasIncremental)
        let spans = await engine.spans(in: NSRange(location: 0, length: (source as NSString).length))
        #expect(texts(spans, .string, in: source).contains("two"))
        #expect(!texts(spans, .number, in: source).contains("2"))
    }

    @Test("只对请求范围跑查询")
    func rangeRestricted() async {
        let source = (0..<200).map { "let v\($0) = \($0)" }.joined(separator: "\n") + "\n"
        let engine = HighlightEngine()
        await engine.rebuild(text: source, language: .swift)
        let first = (source as NSString).range(of: "\n")
        let spans = await engine.spans(in: NSRange(location: 0, length: first.location))
        #expect(spans.allSatisfy { $0.location + $0.length <= first.location })
        #expect(!spans.isEmpty)
    }

    @Test("不支持的语言与超长文本退回词法高亮")
    func fallback() async {
        let engine = HighlightEngine()
        await engine.rebuild(text: "key: value # c\n", language: .yaml)
        #expect(!(await engine.usesTreeSitter))
        let swiftEngine = HighlightEngine()
        await swiftEngine.rebuild(text: "let a = 1", language: .swift)
        #expect(await swiftEngine.usesTreeSitter)
        await swiftEngine.rebuild(text: "x: y", language: .yaml)
        #expect(!(await swiftEngine.usesTreeSitter))
    }

    @Test("捕获名映射")
    func captureNames() {
        #expect(TreeSitterLanguage.kind(forCapture: "keyword.function") == .keyword)
        #expect(TreeSitterLanguage.kind(forCapture: "string.special") == .string)
        #expect(TreeSitterLanguage.kind(forCapture: "function.method") == .function)
        #expect(TreeSitterLanguage.kind(forCapture: "punctuation.bracket") == nil)
        #expect(TreeSitterLanguage.kind(forCapture: "_hidden") == nil)
        #expect(TreeSitterLanguage.kind(forCapture: "constant.builtin") == .keyword)
        #expect(TreeSitterLanguage.kind(forCapture: "variable") == nil)
    }

    @Test("查询切分:保留捕获、忽略注释与字符串里的括号")
    func splitter() {
        let source = """
        ; 注释 (忽略
        (a) @x
        ["(" ")"] @y
        ((b) @c (#eq? @c "x)"))
        "func" @keyword
        """
        let patterns = TreeSitterQuerySplitter.split(source)
        #expect(patterns.count == 4)
        #expect(patterns[0] == "(a) @x")
        #expect(patterns[1] == "[\"(\" \")\"] @y")
        #expect(patterns[3] == "\"func\" @keyword")
    }

    @Test("JS 常量谓词:全大写标识符归为常量(无类别),不影响其他高亮")
    func predicates() async {
        let source = "const MAX = 1;\nlet value = MAX;\n"
        let engine = HighlightEngine()
        await engine.rebuild(text: source, language: .javascript)
        let spans = await engine.spans(in: NSRange(location: 0, length: (source as NSString).length))
        #expect(texts(spans, .keyword, in: source).contains("const"))
        #expect(texts(spans, .number, in: source).contains("1"))
    }

    @Test("公共前后缀推出的编辑区间")
    func editRange() {
        let edit = TreeSitterHighlighter.edit(old: Array("abcdef".utf16), new: Array("abXYdef".utf16))
        #expect(edit.start_byte == 4 && edit.old_end_byte == 6 && edit.new_end_byte == 8)
        let multi = TreeSitterHighlighter.edit(old: Array("a\nb\nc".utf16), new: Array("a\nb\nzz\nc".utf16))
        #expect(multi.start_point.row == 2 && multi.new_end_point.row == 3)
    }
}

@Suite("tree-sitter 性能")
struct TreeSitterPerformanceTests {
    /// 约 5 万行、1.6MB 的 Swift 源码。
    static func bigSource() -> String {
        var lines: [String] = []
        for index in 0..<5_000 {
            lines += [
                "/// 第 \(index) 个类型", "struct Item\(index): Hashable {", "    let id: Int = \(index)",
                "    var name: String { \"item-\\(id)\" }", "    func compute(_ x: Int) -> Int {", "        let y = x * \(index) + 1",
                "        return y > 10 ? y : -y", "    }", "}", "",
            ]
        }
        return lines.joined(separator: "\n") + "\n"
    }

    @Test("5 万行:首次解析、增量重解析与视口查询都在预算内")
    func budgets() async {
        let source = Self.bigSource()
        let engine = HighlightEngine()
        let clock = ContinuousClock()
        let full = await clock.measure { await engine.rebuild(text: source, language: .swift) }
        var edited = source
        edited.insert(contentsOf: "let z = 1\n", at: edited.index(edited.startIndex, offsetBy: 5_000))
        let incremental = await clock.measure { await engine.rebuild(text: edited, language: .swift) }
        let query = await clock.measure { _ = await engine.spans(in: NSRange(location: 20_000, length: 6_000)) }
        func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }
        print("TS-PERF full=\(ms(full)) incremental=\(ms(incremental)) query=\(ms(query)) units=\(source.utf16.count)")
        #expect(await engine.lastParseWasIncremental)
        #expect(ms(query) < 50)
    }
}

@Suite("tree-sitter 显式编辑同步")
struct TreeSitterEditSyncTests {
    /// 在 UTF-16 数组上应用编辑,得到新文本。
    private func apply(_ edit: TextUnitEdit, to units: inout [UInt16]) {
        units.replaceSubrange(edit.location..<(edit.location + edit.oldLength), with: edit.replacement)
    }

    @Test("随机编辑序列:显式编辑同步后的高亮与整体重建完全一致")
    func randomEditsMatchFullRebuild() async {
        let base = (0..<60).map { "let v\($0) = \($0) // 注释😀\n" }.joined()
        var units = Array(base.utf16)
        let engine = HighlightEngine()
        await engine.rebuild(text: base, language: .swift)
        var generator = SystemRandomNumberGenerator()
        let snippets = ["x", "\n", "let q = \"s\"\n", "/* a\nb */", "}", "你好", "😀", ""]
        for round in 0..<40 {
            var edits: [TextUnitEdit] = []
            let before = units.count
            for _ in 0..<Int.random(in: 1...3, using: &generator) {
                let location = Int.random(in: 0...units.count, using: &generator)
                let oldLength = Int.random(in: 0...min(6, units.count - location), using: &generator)
                let snippet = Array((snippets.randomElement(using: &generator) ?? "x").utf16)
                let edit = TextUnitEdit(location: location, oldLength: oldLength, replacement: snippet)
                apply(edit, to: &units)
                edits.append(edit)
            }
            let synced = await engine.applyEdits(edits, oldLength: before, newLength: units.count, language: .swift)
            #expect(synced, "第 \(round) 轮应能增量同步")
            let text = String(decoding: units, as: UTF16.self)
            let reference = HighlightEngine()
            await reference.rebuild(text: text, language: .swift)
            let range = NSRange(location: 0, length: units.count)
            #expect(await engine.spans(in: range) == reference.spans(in: range), "第 \(round) 轮高亮与整体重建不一致")
            #expect(await engine.lastParseWasIncremental)
        }
    }

    @Test("长度对不上、语言不同或没有树时返回 false,由调用方整体重建")
    func mismatchFallsBack() async {
        let engine = HighlightEngine()
        let edit = TextUnitEdit(location: 0, oldLength: 0, replacement: Array("x".utf16))
        #expect(!(await engine.applyEdits([edit], oldLength: 0, newLength: 1, language: .swift)), "没有树")
        await engine.rebuild(text: "let a = 1\n", language: .swift)
        #expect(!(await engine.applyEdits([edit], oldLength: 3, newLength: 11, language: .swift)), "编辑前长度不一致")
        #expect(!(await engine.applyEdits([edit], oldLength: 10, newLength: 99, language: .swift)), "编辑后长度不一致")
        #expect(!(await engine.applyEdits([edit], oldLength: 10, newLength: 11, language: .python)), "语言不同")
        let outOfRange = TextUnitEdit(location: 50, oldLength: 0, replacement: [0x78])
        await engine.rebuild(text: "let a = 1\n", language: .swift)
        #expect(!(await engine.applyEdits([outOfRange], oldLength: 10, newLength: 11, language: .swift)), "越界")
    }
}
