// @author ixxxxoooo
// 运行身份(稳定版 / 开发版)判定与偏好复制的测试。

import Foundation
import Testing
@testable import OMLog

@Suite("AppEnv")
struct AppEnvTests {
    @Test("Bundle ID 以 .dev 结尾为开发版")
    func devByBundleId() {
        #expect(AppEnv.isDev(bundleIdentifier: "com.ixxxxoooo.OhMyAgent.dev", environment: [:]))
        #expect(!AppEnv.isDev(bundleIdentifier: "com.ixxxxoooo.OhMyAgent", environment: [:]))
        #expect(!AppEnv.isDev(bundleIdentifier: nil, environment: [:]))
    }

    @Test("OMA_DEV=1 强制开发版")
    func devByEnvironment() {
        #expect(AppEnv.isDev(bundleIdentifier: "com.ixxxxoooo.OhMyAgent", environment: ["OMA_DEV": "1"]))
        #expect(!AppEnv.isDev(bundleIdentifier: "com.ixxxxoooo.OhMyAgent", environment: ["OMA_DEV": "0"]))
    }

    @Test("开发版偏好只从稳定版复制一次,不覆盖已有键并跳过状态栏键")
    func seedDefaultsOnce() throws {
        let suite = "oma-test-appenv-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("dev", forKey: "keep")
        let stable: () -> [String: Any]? = { ["keep": "stable", "theme": "paper", "NSStatusItem Visible Item-0": true] }

        #expect(AppEnv.seedDevDefaultsIfNeeded(defaults: defaults, stableValues: stable) == 1)
        #expect(defaults.string(forKey: "keep") == "dev")
        #expect(defaults.string(forKey: "theme") == "paper")
        #expect(defaults.object(forKey: "NSStatusItem Visible Item-0") == nil)
        // 第二次不再复制
        #expect(AppEnv.seedDevDefaultsIfNeeded(defaults: defaults, stableValues: stable) == 0)
    }

    @Test("useSystemTimeZone:清除继承来的 TZ,时区回到系统设置")
    func systemTimeZone() {
        setenv("TZ", "Pacific/Honolulu", 1)
        NSTimeZone.resetSystemTimeZone()
        #expect(TimeZone.current.identifier == "Pacific/Honolulu")
        AppEnv.useSystemTimeZone()
        #expect(getenv("TZ") == nil)
        #expect(TimeZone.current.identifier != "Pacific/Honolulu" || TimeZone.autoupdatingCurrent.identifier == "Pacific/Honolulu")
    }
}
