// @author ixxxxoooo
// 会话驻留策略:闲置休眠、进程数上限、可见/忙碌会话豁免、内存压力收紧。

import ChatKit
import Foundation
import Testing
@testable import WorkbenchKit

@Suite("会话驻留策略")
struct SessionResidencyPolicyTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func candidate(_ id: String, idle: TimeInterval, live: Bool = true, can: Bool = true, visible: Bool = false) -> ResidencyCandidate {
        ResidencyCandidate(id: id, isLive: live, canHibernate: can, isVisible: visible, lastUsedAt: now.addingTimeInterval(-idle))
    }

    @Test("闲置超时的空闲会话休眠,未超时的保留")
    func idleTimeout() {
        let list = [candidate("old", idle: 700), candidate("fresh", idle: 60)]
        let victims = SessionResidencyPolicy.victims(candidates: list, limits: ResidencyLimits(idleSeconds: 600, maxLive: 0), now: now)
        #expect(victims == ["old"])
    }

    @Test("闲置时间为 0 表示不按闲置休眠")
    func idleDisabled() {
        let list = [candidate("old", idle: 99_999)]
        #expect(SessionResidencyPolicy.victims(candidates: list, limits: ResidencyLimits(idleSeconds: 0, maxLive: 0), now: now).isEmpty)
    }

    @Test("超过进程数上限时,最久未用的空闲会话先休眠")
    func maxLive() {
        let list = [candidate("a", idle: 30), candidate("b", idle: 300), candidate("c", idle: 100), candidate("d", idle: 10)]
        let victims = SessionResidencyPolicy.victims(candidates: list, limits: ResidencyLimits(idleSeconds: 0, maxLive: 2), now: now)
        #expect(victims == ["b", "c"])
    }

    @Test("可见与忙碌的会话不休眠,上限因此可被突破")
    func exemptions() {
        let list = [
            candidate("visible", idle: 9_000, visible: true),
            candidate("busy", idle: 9_000, can: false),
            candidate("idle", idle: 9_000),
        ]
        let victims = SessionResidencyPolicy.victims(candidates: list, limits: ResidencyLimits(idleSeconds: 600, maxLive: 1), now: now)
        #expect(victims == ["idle"])
    }

    @Test("已经休眠(无进程)的会话不计入上限")
    func dormantNotCounted() {
        let list = [candidate("a", idle: 10), candidate("b", idle: 20), candidate("asleep1", idle: 5000, live: false), candidate("asleep2", idle: 6000, live: false)]
        #expect(SessionResidencyPolicy.victims(candidates: list, limits: ResidencyLimits(idleSeconds: 0, maxLive: 2), now: now).isEmpty)
    }

    @Test("闲置与上限同时命中时不重复、不过度休眠")
    func combined() {
        let list = [candidate("a", idle: 900), candidate("b", idle: 200), candidate("c", idle: 100), candidate("d", idle: 50)]
        let victims = SessionResidencyPolicy.victims(candidates: list, limits: ResidencyLimits(idleSeconds: 600, maxLive: 3), now: now)
        #expect(victims == ["a"])
    }

    @Test("内存紧张时闲置缩到 1 分钟、只留 1 个进程")
    func pressure() {
        let tight = ResidencyLimits(idleSeconds: 600, maxLive: 4).underPressure
        #expect(tight.idleSeconds == 60)
        #expect(tight.maxLive == 1)
        #expect(ResidencyLimits(idleSeconds: 0, maxLive: 0).underPressure.idleSeconds == 60)
        let list = [candidate("a", idle: 100), candidate("b", idle: 5)]
        #expect(SessionResidencyPolicy.victims(candidates: list, limits: tight, now: now) == ["a"])
    }

    @Test("驻留偏好有缺省值并限制范围")
    func prefs() {
        let defaults = UserDefaults(suiteName: "oma-residency-\(UUID().uuidString)")!
        #expect(ClientPrefs.idleHibernateMinutes(defaults) == 10)
        #expect(ClientPrefs.maxLiveSessions(defaults) == 3)
        defaults.set(9_999, forKey: ClientPrefs.Key.idleHibernateMinutes)
        defaults.set(-5, forKey: ClientPrefs.Key.maxLiveSessions)
        #expect(ClientPrefs.idleHibernateMinutes(defaults) == 240)
        #expect(ClientPrefs.maxLiveSessions(defaults) == 0)
    }
}

@MainActor
@Suite("会话休眠入口")
struct SessionHibernationTests {
    @Test("未连接的会话不能休眠,也不是休眠态")
    func notConnected() {
        let session = SessionModel(workspace: FileManager.default.temporaryDirectory)
        session.attention = AttentionCenter()
        #expect(!session.canHibernate)
        #expect(!session.hibernate())
        #expect(!session.isHibernated)
    }

    @Test("工作台按驻留策略检查时,没有已连接会话则不休眠任何会话")
    func enforceWithoutLive() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oma-resid-\(UUID().uuidString)")
        let dir = root.appendingPathComponent("alpha")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkbenchModel(store: WorkbenchStore(fileURL: root.appendingPathComponent("state/workbench.json")), autoConnect: false) { url in
            let session = SessionModel(workspace: url)
            session.attention = AttentionCenter()
            return session
        }
        _ = try #require(model.openProject(dir))
        model.residencyLimits = { ResidencyLimits(idleSeconds: 1, maxLive: 1) }
        #expect(model.enforceResidency(now: Date().addingTimeInterval(3600)) == 0)
        model.startResidencyMonitor()
        model.shutdownAll()
    }
}
