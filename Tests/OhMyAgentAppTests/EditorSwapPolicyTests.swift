// @author ixxxxoooo
// 切换文件不闪屏的判定:新编辑器未就绪时保留旧标签,就绪、超时、旧标签被关闭或无需等待时直接换。

import Foundation
import Testing
@testable import OhMyAgentApp

@Suite("编辑器切换保留策略")
struct EditorSwapPolicyTests {
    @Test("新文件编辑器未就绪:保留旧标签;就绪后放行")
    func holdsUntilReady() {
        #expect(EditorSwapPolicy.shouldHold(targetPath: "/p/b.swift", targetKey: "b", shownKey: "a", shownAlive: true, ready: []))
        #expect(!EditorSwapPolicy.shouldHold(targetPath: "/p/b.swift", targetKey: "b", shownKey: "a", shownAlive: true, ready: ["/p/b.swift"]))
    }

    @Test("首次显示、同一槽位、旧标签已关闭、非文件标签:不保留")
    func releasesWhenNothingToKeep() {
        #expect(!EditorSwapPolicy.shouldHold(targetPath: "/p/b.swift", targetKey: "b", shownKey: nil, shownAlive: false, ready: []))
        #expect(!EditorSwapPolicy.shouldHold(targetPath: "/p/b.swift", targetKey: "b", shownKey: "b", shownAlive: true, ready: []))
        #expect(!EditorSwapPolicy.shouldHold(targetPath: "/p/b.swift", targetKey: "b", shownKey: "a", shownAlive: false, ready: []))
        #expect(!EditorSwapPolicy.shouldHold(targetPath: nil, targetKey: "b", shownKey: "a", shownAlive: true, ready: []))
    }

    @Test("图片 / PDF 不会上报就绪,不等待")
    func binaryDoesNotWait() {
        #expect(!EditorSwapPolicy.isHoldable(path: "/p/logo.png"))
        #expect(EditorSwapPolicy.isHoldable(path: "/p/main.swift"))
        #expect(!EditorSwapPolicy.shouldHold(targetPath: "/p/logo.png", targetKey: "b", shownKey: "a", shownAlive: true, ready: []))
    }

    @Test("预览标签被新预览原位替换仍保留旧画面;关闭标签、新增标签则按各自语义")
    func previewReplacementIsKeepable() {
        let old = UUID(), new = UUID(), other = UUID()
        // 预览替换:旧 id 消失、新 id 出现,标签数不变 → 保留
        #expect(EditorSwapPolicy.isShownKeepable(shownID: old, siblingIDs: [other, old], currentIDs: [other, new], targetID: new))
        // 关闭了正在显示的标签:数量减少 → 不保留
        #expect(!EditorSwapPolicy.isShownKeepable(shownID: old, siblingIDs: [other, old], currentIDs: [other], targetID: other))
        // 旧标签仍在(普通新开一个标签)→ 保留
        #expect(EditorSwapPolicy.isShownKeepable(shownID: old, siblingIDs: [old], currentIDs: [old, new], targetID: new))
    }
}
