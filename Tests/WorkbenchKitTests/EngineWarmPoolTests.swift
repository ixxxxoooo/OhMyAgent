// @author ixxxxoooo
// 引擎预热池:规划、认领、容量与回收。

import AgentHost
import ChatKit
import Foundation
import Testing
@testable import WorkbenchKit

@Suite("引擎预热池")
@MainActor
struct EngineWarmPoolTests {
    private func descriptor(_ id: String) -> AgentDescriptor {
        AgentDescriptor(id: id, name: id, kind: .genericACP, command: "/usr/bin/true")
    }

    private func pool(capacity: Int = 4) -> EngineWarmPool {
        let pool = EngineWarmPool()
        pool.capacity = capacity
        pool.factory = { url, descriptor in SessionModel(workspace: url, descriptor: descriptor) }
        return pool
    }

    @Test("规划:关闭为空;智能取最近用过且已启用的引擎并去重限量;全部取其余已启用引擎")
    func planner() {
        let enabled = ["claude", "codex", "gemini", "pi", "opencode", "x"]
        #expect(EngineWarmPlanner.plan(mode: .off, currentEngineID: "claude", recentEngineIDs: ["codex"], enabledEngineIDs: enabled).isEmpty)
        let smart = EngineWarmPlanner.plan(mode: .smart, currentEngineID: "claude", recentEngineIDs: ["claude", "codex", "codex", "gone", "gemini", "pi"], enabledEngineIDs: enabled)
        #expect(smart == ["codex", "gemini"])
        let all = EngineWarmPlanner.plan(mode: .all, currentEngineID: "claude", recentEngineIDs: [], enabledEngineIDs: enabled)
        #expect(all == ["codex", "gemini"])
        #expect(EngineWarmPlanner.planForPicker(mode: .off, currentEngineID: nil, enabledEngineIDs: enabled).isEmpty)
        #expect(EngineWarmPlanner.planForPicker(mode: .smart, currentEngineID: "codex", enabledEngineIDs: enabled).first == "claude")
    }

    @Test("预热后可认领,认领后移出池;同键不重复预热")
    func warmAndTake() {
        let pool = pool()
        let url = URL(fileURLWithPath: "/tmp/warm-a")
        #expect(pool.warm(workspace: url, descriptor: descriptor("e1")))
        #expect(!pool.warm(workspace: url, descriptor: descriptor("e1")))
        #expect(pool.isWarm(agentID: "e1", workspace: url))
        let taken = pool.take(agentID: "e1", workspace: url)
        #expect(taken?.descriptor.id == "e1")
        #expect(pool.standbyCount == 0)
        #expect(pool.take(agentID: "e1", workspace: url) == nil)
        taken?.shutdown()
    }

    @Test("容量上限与按工作区回收")
    func capacityAndDiscard() {
        let pool = pool(capacity: 2)
        let a = URL(fileURLWithPath: "/tmp/warm-a")
        let b = URL(fileURLWithPath: "/tmp/warm-b")
        #expect(pool.warm(workspace: a, descriptor: descriptor("e1")))
        #expect(pool.warm(workspace: b, descriptor: descriptor("e1")))
        #expect(!pool.warm(workspace: a, descriptor: descriptor("e2")))
        pool.discardAll(except: a.path)
        #expect(pool.isWarm(agentID: "e1", workspace: a))
        #expect(!pool.isWarm(agentID: "e1", workspace: b))
        pool.shutdownAll()
        #expect(pool.standbyCount == 0)
    }

    @Test("没有工厂或引擎未启用时不预热")
    func guards() {
        let empty = EngineWarmPool()
        #expect(!empty.warm(workspace: URL(fileURLWithPath: "/tmp/x"), descriptor: descriptor("e1")))
        var disabled = descriptor("e2")
        disabled.enabled = false
        #expect(!pool().warm(workspace: URL(fileURLWithPath: "/tmp/x"), descriptor: disabled))
    }

    @Test("预热模式偏好:缺省为智能,非法值回退智能")
    func modePreference() {
        let defaults = UserDefaults(suiteName: "oma.test.warm.\(UUID().uuidString)") ?? .standard
        #expect(WarmMode.current(defaults) == .smart)
        defaults.set("乱写", forKey: WarmMode.preferenceKey)
        #expect(WarmMode.current(defaults) == .smart)
        defaults.set("all", forKey: WarmMode.preferenceKey)
        #expect(WarmMode.current(defaults) == .all)
    }
}
