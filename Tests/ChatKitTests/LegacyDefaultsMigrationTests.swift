// @author ixxxxoooo
// 旧 Bundle ID 偏好迁移:复制、不覆盖、跳过状态栏键、仅执行一次。

import Foundation
import Testing
@testable import ChatKit

@Suite("旧 Bundle ID 偏好迁移")
struct LegacyDefaultsMigrationTests {
    /// 创建隔离的临时偏好域。
    private func makeDefaults() -> (UserDefaults, String) {
        let name = "oma.test.legacy.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name) ?? .standard
        defaults.removePersistentDomain(forName: name)
        return (defaults, name)
    }

    @Test("复制旧域键值,不覆盖新域已有值,并跳过状态栏键")
    func copiesWithoutOverwrite() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("dark", forKey: "theme")
        let legacy: [String: Any] = ["theme": "light", "fontScale": 1.2, "NSStatusItem VisibleCC Item-0": 0, "AppleLanguages": ["en"]]
        let copied = LegacyDefaultsMigration.migrateIfNeeded(defaults: defaults, domain: name, legacyDomain: "legacy.x", legacyValues: { _ in legacy })
        #expect(copied == 2)
        #expect(defaults.string(forKey: "theme") == "dark")
        #expect(defaults.double(forKey: "fontScale") == 1.2)
        #expect(defaults.object(forKey: "NSStatusItem VisibleCC Item-0") == nil)
        #expect(defaults.array(forKey: "AppleLanguages") as? [String] == ["en"])
    }

    @Test("只执行一次")
    func runsOnce() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let first = LegacyDefaultsMigration.migrateIfNeeded(defaults: defaults, domain: name, legacyDomain: "legacy.x", legacyValues: { _ in ["a": 1] })
        let second = LegacyDefaultsMigration.migrateIfNeeded(defaults: defaults, domain: name, legacyDomain: "legacy.x", legacyValues: { _ in ["b": 2] })
        #expect(first == 1)
        #expect(second == 0)
        #expect(defaults.object(forKey: "b") == nil)
    }

    @Test("旧域为空时只写标记")
    func emptyLegacy() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(LegacyDefaultsMigration.migrateIfNeeded(defaults: defaults, domain: name, legacyDomain: "legacy.x", legacyValues: { _ in nil }) == 0)
        #expect(defaults.bool(forKey: LegacyDefaultsMigration.markerKey))
    }

    @Test("空域名直接忽略")
    func emptyDomain() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(LegacyDefaultsMigration.migrateIfNeeded(defaults: defaults, domain: name, legacyDomain: "", legacyValues: { _ in ["a": 1] }) == 0)
        #expect(!defaults.bool(forKey: LegacyDefaultsMigration.markerKey))
    }
}
