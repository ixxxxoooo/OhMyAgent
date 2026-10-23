// @author ixxxxoooo
// 提交署名尾注。

import Testing
@testable import GitKit

@Suite("提交署名")
struct CommitTrailerTests {
    @Test("关闭时只去除首尾空白,不追加")
    func disabled() {
        #expect(CommitTrailer.apply(to: "  feat: 新功能\n", enabled: false) == "feat: 新功能")
    }

    @Test("开启时空一行追加署名,且不重复")
    func enabled() {
        let once = CommitTrailer.apply(to: "feat: 新功能", enabled: true)
        #expect(once == "feat: 新功能\n\n" + CommitTrailer.coAuthorLine)
        #expect(CommitTrailer.apply(to: once, enabled: true) == once)
    }

    @Test("已有尾注块时紧接着追加;空说明不追加")
    func existingTrailers() {
        let result = CommitTrailer.apply(to: "fix: 修复\n\nSigned-off-by: A <a@b.c>", enabled: true)
        #expect(result == "fix: 修复\n\nSigned-off-by: A <a@b.c>\n" + CommitTrailer.coAuthorLine)
        #expect(CommitTrailer.apply(to: "  ", enabled: true).isEmpty)
    }
}

@Suite("提交尾注:多行")
struct CommitTrailerLinesTests {
    @Test("多行尾注一次追加,已有的行(忽略大小写)不重复")
    func multipleLinesDeduped() {
        let first = CommitTrailer.apply(to: "feat: 新功能", lines: ["Co-authored-by: A <a@x.com>", "Co-authored-by: B <b@x.com>"])
        #expect(first == "feat: 新功能\n\nCo-authored-by: A <a@x.com>\nCo-authored-by: B <b@x.com>")
        let again = CommitTrailer.apply(to: first, lines: ["co-authored-by: a <A@x.com>", "Co-authored-by: C <c@x.com>"])
        #expect(again.hasSuffix("B <b@x.com>\nCo-authored-by: C <c@x.com>"))
        #expect(again.components(separatedBy: "a@x.com").count == 2)
    }

    @Test("没有要追加的行或说明为空时原样返回")
    func noLines() {
        #expect(CommitTrailer.apply(to: " fix: x \n", lines: []) == "fix: x")
        #expect(CommitTrailer.apply(to: "  ", lines: ["Co-authored-by: A <a@x.com>"]).isEmpty)
    }
}
