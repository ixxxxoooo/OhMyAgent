// @author ixxxxoooo
// 页脚分支切换器:列表过滤与远程分支名转换。

import Foundation
import GitKit
import Testing

@testable import OhMyAgentApp

@Suite("分支列表处理")
struct BranchListingTests {
    private func branch(_ name: String, remote: Bool = false) -> GitBranch {
        GitBranch(name: name, isCurrent: false, isRemote: remote, upstream: nil, hash: "abc", subject: "")
    }

    @Test("按关键字过滤,不区分大小写;空关键字返回全部")
    func filtering() {
        let all = [branch("main"), branch("feature/Login"), branch("fix/typo")]
        #expect(BranchListing.filter(all, query: "").count == 3)
        #expect(BranchListing.filter(all, query: "login").map(\.name) == ["feature/Login"])
        #expect(BranchListing.filter(all, query: "zzz").isEmpty)
    }

    @Test("远程分支名转为本地分支名:只去掉第一段远端名")
    func localName() {
        #expect(BranchListing.localName(of: "origin/main") == "main")
        #expect(BranchListing.localName(of: "origin/feature/x") == "feature/x")
        #expect(BranchListing.localName(of: "main") == "main")
    }
}
