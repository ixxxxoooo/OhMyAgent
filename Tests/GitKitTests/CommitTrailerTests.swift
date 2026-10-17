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
