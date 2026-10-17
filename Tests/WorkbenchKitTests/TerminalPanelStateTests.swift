// @author ixxxxoooo
// 终端面板多终端状态:新建、激活、循环、关闭、重命名与持久化往返。

import Foundation
import Testing

@testable import WorkbenchKit

@Suite("终端面板多终端状态")
struct TerminalPanelStateTests {
    @Test("初始只有一个终端,标识沿用旧版 bottom:{根}")
    func initialInstance() {
        let state = TerminalPanelState(root: "/p")
        #expect(state.instances.map(\.id) == ["bottom:/p"])
        #expect(state.activeID == "bottom:/p")
        #expect(state.active.serial == 1)
    }

    @Test("新建终端并激活,序号递增且不复用")
    func addAndSerial() {
        var state = TerminalPanelState(root: "/p")
        let second = state.add()
        #expect(second?.id == "bottom:/p#2" && second?.serial == 2)
        #expect(state.activeID == "bottom:/p#2")
        state.close("bottom:/p#2")
        let third = state.add()
        #expect(third?.serial == 3, "关闭后序号不复用")
    }

    @Test("数量上限")
    func limit() {
        var state = TerminalPanelState(root: "/p")
        for _ in 1..<TerminalPanelState.maxInstances { #expect(state.add() != nil) }
        #expect(!state.canAdd && state.add() == nil)
        #expect(state.instances.count == TerminalPanelState.maxInstances)
    }

    @Test("循环切换与激活")
    func cycleAndActivate() {
        var state = TerminalPanelState(root: "/p")
        state.add(); state.add()
        let ids = state.instances.map(\.id)
        state.activate(ids[0])
        state.cycle(1)
        #expect(state.activeID == ids[1])
        state.cycle(-1); state.cycle(-1)
        #expect(state.activeID == ids[2], "向前越界回到最后一个")
        state.activate("不存在")
        #expect(state.activeID == ids[2])
    }

    @Test("关闭激活项激活相邻项;关闭最后一个重置并提示隐藏")
    func close() {
        var state = TerminalPanelState(root: "/p")
        state.add(); state.add()
        let ids = state.instances.map(\.id)
        state.activate(ids[1])
        #expect(state.close(ids[1]) == .remaining(active: ids[2]))
        #expect(state.close(ids[2]) == .remaining(active: ids[0]))
        #expect(state.close("x") == .unknown)
        #expect(state.close(ids[0]) == .closedLast)
        #expect(state.instances.count == 1 && state.activeID == "bottom:/p")
    }

    @Test("关闭其他:只保留指定终端")
    func closeOthers() {
        var state = TerminalPanelState(root: "/p")
        state.add(); state.add()
        let keep = state.instances[1].id
        let closed = state.closeOthers(keeping: keep)
        #expect(closed.count == 2 && state.instances.map(\.id) == [keep] && state.activeID == keep)
    }

    @Test("重命名:空白恢复自动标题,过长截断")
    func rename() {
        var state = TerminalPanelState(root: "/p")
        let id = state.active.id
        state.rename(id, to: "  构建  ")
        #expect(state.active.customTitle == "构建")
        state.rename(id, to: "   ")
        #expect(state.active.customTitle == nil)
        state.rename(id, to: String(repeating: "长", count: 100))
        #expect(state.active.customTitle?.count == 40)
    }

    @Test("编码往返与损坏数据修复")
    func codableAndNormalize() throws {
        var state = TerminalPanelState(root: "/p")
        state.add()
        let data = try JSONEncoder().encode(state)
        var decoded = try JSONDecoder().decode(TerminalPanelState.self, from: data)
        #expect(decoded == state)
        decoded.normalize()
        #expect(decoded.add()?.serial == 3)
        let broken = #"{"root":"/p","instances":[],"activeID":"zzz","nextSerial":1}"#
        var repaired = try JSONDecoder().decode(TerminalPanelState.self, from: Data(broken.utf8))
        repaired.normalize()
        #expect(repaired.instances.count == 1 && repaired.activeID == "bottom:/p")
    }
}
