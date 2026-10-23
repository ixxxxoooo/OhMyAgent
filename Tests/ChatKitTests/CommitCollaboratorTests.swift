// @author ixxxxoooo
// 提交协作者:校验、尾注行、存取与智能体提示。

import Foundation
import Testing

@testable import ChatKit

@Suite("提交协作者")
struct CommitCollaboratorTests {
    @Test("名字与邮箱都合法才可用;含尖括号或换行的名字不可用")
    func validation() {
        #expect(CommitCollaborator(name: " 张三 ", email: " zs@example.com ").trailerLine == "Co-authored-by: 张三 <zs@example.com>")
        #expect(CommitCollaborator(name: "", email: "a@b.co").trailerLine == nil)
        #expect(CommitCollaborator(name: "A", email: "not-an-email").trailerLine == nil)
        #expect(CommitCollaborator(name: "A <x>", email: "a@b.co").trailerLine == nil)
        #expect(CommitCollaborator(name: "A\nB", email: "a@b.co").trailerLine == nil)
        #expect(CommitCollaborator(name: "A", email: "a b@c.co").trailerLine == nil)
    }

    @Test("名单编码往返;空串与损坏文本得到空名单")
    func roundTrip() {
        let list = [CommitCollaborator(name: "A", email: "a@b.co"), CommitCollaborator(name: "B", email: "b@b.co")]
        #expect(CommitCollaborator.decode(CommitCollaborator.encode(list)) == list)
        #expect(CommitCollaborator.decode("").isEmpty)
        #expect(CommitCollaborator.decode("{坏的").isEmpty)
    }

    @Test("尾注行按邮箱去重(忽略大小写)并跳过不可用项")
    func trailerLinesDedup() {
        let list = [CommitCollaborator(name: "A", email: "a@b.co"), CommitCollaborator(name: "A2", email: "A@B.co"),
                    CommitCollaborator(name: "", email: "x@y.co")]
        #expect(CommitCollaborator.trailerLines(list) == ["Co-authored-by: A <a@b.co>"])
    }

    @Test("智能体提示:无可用协作者为 nil,否则逐行列出尾注")
    func agentPrompt() throws {
        #expect(CommitCollaborator.agentPrompt([]) == nil)
        #expect(CommitCollaborator.agentPrompt([CommitCollaborator(name: "", email: "")]) == nil)
        let prompt = try #require(CommitCollaborator.agentPrompt([CommitCollaborator(name: "A", email: "a@b.co")]))
        #expect(prompt.hasSuffix("Co-authored-by: A <a@b.co>"))
    }
}
