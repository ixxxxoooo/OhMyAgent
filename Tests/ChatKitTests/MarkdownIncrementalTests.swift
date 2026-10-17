// @author ixxxxoooo
// Markdown 增量解析测试:流式追加时,增量结果必须与整段解析完全一致。

import Foundation
import Testing
@testable import ChatKit

@Suite("Markdown 增量解析")
struct MarkdownIncrementalTests {
    /// 覆盖全部块类型与易出边界问题的写法(未闭合围栏、表格头先于分隔行、列表续行、中文与 emoji 等多字节字符)。
    private static let sample = """
    # 标题 一

    第一段文字,含 **粗体** 与 `code` 和 emoji 🚀🎉。
    同一段的第二行。

    | 列A | 列B |
    |-----|-----|
    | 1 | 2 |
    | 3 | 4 |

    - 列表项一
      续行内容
    - [ ] 任务
    - [x] 已完成
    1. 有序一
    2. 有序二

    > 引用第一行
    > 引用第二行

    ---

    ```swift
    let a = 1

    func f() { print("hi") }
    ```

    段落紧接着表格头
    | x | y |
    |---|---|
    | 5 | 6 |

    ~~~
    未闭合的围栏里有 # 井号 和 - 横线
    再来一行
    """

    @Test("逐字符追加:每一步增量结果都等于整段解析")
    func everyPrefix() {
        var state: MarkdownParseState?
        var text = ""
        for character in Self.sample {
            text.append(character)
            let next = MarkdownParser.parseState(text, continuing: state)
            #expect(next.blocks == MarkdownParser.parse(text), "前缀长度 \(text.count) 不一致")
            state = next
        }
    }

    @Test("按不同步长追加(模拟分片大小不一的流式输出)",
          arguments: [1, 2, 3, 5, 7, 13, 40, 200])
    func chunked(step: Int) {
        var state: MarkdownParseState?
        let characters = Array(Self.sample)
        var text = ""
        var index = 0
        while index < characters.count {
            let end = min(index + step, characters.count)
            text.append(contentsOf: characters[index..<end])
            let next = MarkdownParser.parseState(text, continuing: state)
            #expect(next.blocks == MarkdownParser.parse(text), "步长 \(step),长度 \(text.count)")
            state = next
            index = end
        }
    }

    @Test("文本被改写(不是前缀扩展)时退回整段解析")
    func notAnExtension() {
        let first = MarkdownParser.parseState("# 旧标题\n\n旧段落")
        let rewritten = "# 新标题\n\n新段落\n\n- 项"
        let result = MarkdownParser.parseState(rewritten, continuing: first)
        #expect(result.blocks == MarkdownParser.parse(rewritten))
        // 文本变短也不能复用
        let shorter = MarkdownParser.parseState("# 旧", continuing: first)
        #expect(shorter.blocks == MarkdownParser.parse("# 旧"))
    }

    @Test("空文本与空状态")
    func emptyCases() {
        #expect(MarkdownParser.parseState("", continuing: nil).blocks.isEmpty)
        let empty = MarkdownParser.parseState("")
        #expect(MarkdownParser.parseState("你好", continuing: empty).blocks == MarkdownParser.parse("你好"))
    }

    @Test("增量解析不改变更早的块,最后一个块随追加增长")
    func earlierBlocksStable() {
        let base = "# 标题\n\n第一段\n\n第二段"
        let state = MarkdownParser.parseState(base)
        let extended = MarkdownParser.parseState(base + "继续追加", continuing: state)
        #expect(Array(extended.blocks.prefix(2)) == Array(state.blocks.prefix(2)))
        #expect(extended.blocks.last == .paragraph("第二段继续追加"))
    }

    @Test("半截列表标记写完后接续上一个列表,而不是另起一个")
    func listMarkerCompletion() {
        let before = MarkdownParser.parseState("- 一\n-")
        let after = MarkdownParser.parseState("- 一\n- 二", continuing: before)
        #expect(after.blocks == MarkdownParser.parse("- 一\n- 二"))
        if case .list(let items) = after.blocks.first { #expect(items.count == 2) } else { Issue.record("应为单个列表") }
    }
}
