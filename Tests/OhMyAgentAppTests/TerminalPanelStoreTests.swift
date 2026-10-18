// @author ixxxxoooo
// 终端面板多终端仓库:新建/切换/关闭联动终端进程,重启后恢复实例列表。

import Foundation
import Testing
import WorkbenchKit

@testable import OhMyAgentApp

@MainActor
@Suite("终端面板仓库")
struct TerminalPanelStoreTests {
    private func makeDefaults() -> UserDefaults {
        let name = "oma.test.panel.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name) ?? .standard
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("新建终端激活新实例;关闭实例会结束对应进程;关闭最后一个返回 closedLast")
    func addAndClose() async {
        let root = "/tmp/oma-panel-\(UUID().uuidString)"
        let store = TerminalPanelStore(defaults: makeDefaults())
        let second = store.addTerminal(root: root)
        #expect(second != nil && store.state(for: root).activeID == second?.id)
        guard let second else { return }
        let controller = TerminalStore.shared.controller(for: second.id, fallbackDirectory: NSTemporaryDirectory())
        #expect(controller.isRunning)
        #expect(store.close(second.id, root: root) == .remaining(active: TerminalPanelState.baseID(root)))
        for _ in 0..<100 where controller.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
        #expect(!controller.isRunning)
        #expect(TerminalStore.shared.controllers[second.id] == nil)
        #expect(store.close(TerminalPanelState.baseID(root), root: root) == .closedLast)
        #expect(store.state(for: root).instances.count == 1)
    }

    @Test("实例列表持久化:重新创建仓库后保留实例、激活项与自定义名称")
    func persistence() {
        let defaults = makeDefaults()
        let root = "/tmp/oma-persist"
        let first = TerminalPanelStore(defaults: defaults)
        let second = first.addTerminal(root: root)
        first.rename(second?.id ?? "", to: "构建", root: root)
        first.activate(TerminalPanelState.baseID(root), root: root)
        let restored = TerminalPanelStore(defaults: defaults)
        let state = restored.state(for: root)
        #expect(state.instances.count == 2)
        #expect(state.activeID == TerminalPanelState.baseID(root))
        #expect(restored.title(of: state.instances[1]) == "构建")
    }

    @Test("拖动排序持久化,命名新建的终端")
    func moveAndNamedAdd() {
        let defaults = makeDefaults()
        let root = "/tmp/oma-move"
        let store = TerminalPanelStore(defaults: defaults)
        let second = store.addTerminal(root: root, name: "服务")
        #expect(second?.customTitle == "服务")
        store.move(second?.id ?? "", before: TerminalPanelState.baseID(root), root: root)
        let restored = TerminalPanelStore(defaults: defaults).state(for: root)
        #expect(restored.instances.map(\.id) == [second?.id ?? "", TerminalPanelState.baseID(root)])
        store.close(second?.id ?? "", root: root)
        store.close(TerminalPanelState.baseID(root), root: root)
    }

    @Test("标题:自定义 > shell 上报 > 终端 N")
    func titles() {
        let store = TerminalPanelStore(defaults: makeDefaults())
        let root = "/tmp/oma-title"
        store.addTerminal(root: root)
        let state = store.state(for: root)
        #expect(store.title(of: state.instances[0]).hasPrefix("终端") || store.title(of: state.instances[0]).lowercased().hasPrefix("terminal"))
        #expect(store.title(of: state.instances[1]).hasSuffix("2"))
    }

    @Test("损坏的持久化数据不会让仓库崩溃")
    func corruptData() {
        let defaults = makeDefaults()
        defaults.set(Data("不是 JSON".utf8), forKey: TerminalPanelStore.defaultsKey)
        let store = TerminalPanelStore(defaults: defaults)
        #expect(store.state(for: "/x").instances.count == 1)
    }
}

@Suite("终端拖动载荷")
struct TerminalDragPayloadTests {
    @Test("往返解析;非终端载荷或空 id 返回 nil")
    func roundTrip() {
        #expect(TerminalDragPayload.parse(TerminalDragPayload.make("bottom:/p#2")) == "bottom:/p#2")
        #expect(TerminalDragPayload.parse("tab:123") == nil)
        #expect(TerminalDragPayload.parse(TerminalDragPayload.make("")) == nil)
    }
}
