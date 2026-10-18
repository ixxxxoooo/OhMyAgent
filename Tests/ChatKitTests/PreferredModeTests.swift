// @author ixxxxoooo
import ACPKit
import Foundation
import Testing
@testable import ChatKit

/// 权限模式偏好测试。
@Suite struct PreferredModeTests {
    private func modeOption(current: String) -> SessionConfigOption {
        SessionConfigOption(json: .object([
            "id": .string("mode"), "name": .string("Mode"), "category": .string("mode"), "type": .string("select"),
            "currentValue": .string(current),
            "options": .array([
                .object(["value": .string("default"), "name": .string("Default")]),
                .object(["value": .string("auto"), "name": .string("Auto")]),
            ]),
        ]))
    }

    @Test func targetSwitchesWhenDifferent() {
        #expect(PreferredMode.target(saved: "auto", option: modeOption(current: "default")) == "auto")
    }

    @Test func targetNilWhenSameUnknownOrMissing() {
        #expect(PreferredMode.target(saved: "auto", option: modeOption(current: "auto")) == nil)
        #expect(PreferredMode.target(saved: "plan", option: modeOption(current: "default")) == nil)
        #expect(PreferredMode.target(saved: nil, option: modeOption(current: "default")) == nil)
        #expect(PreferredMode.target(saved: "auto", option: nil) == nil)
    }

    @Test func saveAndLoadPerAgent() throws {
        let defaults = try #require(UserDefaults(suiteName: "oma-test-preferred-mode"))
        defer { defaults.removePersistentDomain(forName: "oma-test-preferred-mode") }
        PreferredMode.save("auto", agentId: "a", defaults)
        #expect(PreferredMode.saved(agentId: "a", defaults) == "auto")
        #expect(PreferredMode.saved(agentId: "b", defaults) == nil)
        PreferredMode.save("", agentId: "a", defaults)
        #expect(PreferredMode.saved(agentId: "a", defaults) == nil)
    }
}
