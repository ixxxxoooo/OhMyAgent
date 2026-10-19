// @author ixxxxoooo
// 落盘序列化器测试:较新的快照不会被较旧的覆盖;后台保存最终落盘。

import ACPKit
import AgentHost
import ChatKit
import Foundation
import Testing
@testable import WorkbenchKit

@MainActor
@Suite("工作台落盘序列化")
struct SaveSequencerTests {
    private func makeRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("oma-wb-\(UUID().uuidString)")
    }

    @Test("较旧代号的快照被丢弃,不会覆盖较新的")
    func olderGenerationDropped() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkbenchStore(fileURL: root.appendingPathComponent("workbench.json"))
        let sequencer = SaveSequencer()
        var older = WorkbenchState()
        older.layout.leftWidth = 250
        var newer = WorkbenchState()
        newer.layout.leftWidth = 400
        let first = sequencer.nextGeneration()
        let second = sequencer.nextGeneration()
        #expect(second > first)
        #expect(try sequencer.write(generation: second, state: newer, store: store))
        #expect(try !sequencer.write(generation: first, state: older, store: store))
        #expect(store.load()?.layout.leftWidth == 400)
        // 更新的快照仍可继续写入
        var latest = WorkbenchState()
        latest.layout.leftWidth = 300
        #expect(try sequencer.write(generation: sequencer.nextGeneration(), state: latest, store: store))
        #expect(store.load()?.layout.leftWidth == 300)
    }

    @Test("后台保存:修改布局后防抖到期即落盘;随后的同步保存不会被旧快照覆盖")
    func backgroundSaveEventuallyWrites() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkbenchStore(fileURL: root.appendingPathComponent("state/workbench.json"))
        let model = WorkbenchModel(store: store, autoConnect: false) { url in
            let session = SessionModel(workspace: url)
            session.attention = AttentionCenter()
            return session
        }
        model.layout.leftWidth = 333
        var saved: Double?
        for _ in 0..<60 {
            saved = store.load()?.layout.leftWidth
            if saved == 333 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(saved == 333, "后台保存应在防抖后落盘")
        // 先触发后台保存再立刻同步保存:最终文件必须是较新的值
        model.layout.leftWidth = 350
        model.saveInBackground()
        model.layout.leftWidth = 360
        model.saveNow()
        try await Task.sleep(for: .milliseconds(300))
        #expect(store.load()?.layout.leftWidth == 360)
    }
}
