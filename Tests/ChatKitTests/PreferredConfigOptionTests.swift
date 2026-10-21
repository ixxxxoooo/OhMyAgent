// @author ixxxxoooo
import ACPKit
import Foundation
import Testing
@testable import ChatKit

/// 会话配置偏好(模式/模型/思考强度)与引擎偏好测试。
@Suite struct PreferredConfigOptionTests {
    private func option(_ category: String, id: String? = nil, current: String, values: [String]) -> SessionConfigOption {
        SessionConfigOption(json: .object([
            "id": .string(id ?? category), "name": .string(category), "category": .string(category), "type": .string("select"),
            "currentValue": .string(current),
            "options": .array(values.map { .object(["value": .string($0), "name": .string($0)]) }),
        ]))
    }

    private func makeDefaults(_ name: String) throws -> UserDefaults {
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func modeKeepsLegacyKey() {
        #expect(PreferredConfigOption.key(category: "mode", agentId: "a") == PreferredMode.key(agentId: "a"))
        #expect(PreferredConfigOption.key(category: "model", agentId: "a") == "chat.preferred.model.a")
    }

    @Test func saveAndLoadPerAgentAndCategory() throws {
        let name = "oma-test-preferred-config"
        let defaults = try makeDefaults(name)
        defer { defaults.removePersistentDomain(forName: name) }
        PreferredConfigOption.save("opus", category: "model", agentId: "a", defaults)
        PreferredConfigOption.save("high", category: "thought_level", agentId: "a", defaults)
        #expect(PreferredConfigOption.saved(category: "model", agentId: "a", defaults) == "opus")
        #expect(PreferredConfigOption.saved(category: "thought_level", agentId: "a", defaults) == "high")
        #expect(PreferredConfigOption.saved(category: "model", agentId: "b", defaults) == nil)
        PreferredConfigOption.save("", category: "model", agentId: "a", defaults)
        #expect(PreferredConfigOption.saved(category: "model", agentId: "a", defaults) == nil)
    }

    @Test func saveIgnoresUnknownCategoryAndEmptyAgent() throws {
        let name = "oma-test-preferred-config-ignore"
        let defaults = try makeDefaults(name)
        defer { defaults.removePersistentDomain(forName: name) }
        PreferredConfigOption.save("x", category: "other", agentId: "a", defaults)
        PreferredConfigOption.save("x", category: "model", agentId: "", defaults)
        #expect(PreferredConfigOption.saved(category: "other", agentId: "a", defaults) == nil)
        #expect(PreferredConfigOption.saved(category: "model", agentId: "", defaults) == nil)
    }

    @Test func changesCoverModeModelThoughtInOrder() throws {
        let name = "oma-test-preferred-config-changes"
        let defaults = try makeDefaults(name)
        defer { defaults.removePersistentDomain(forName: name) }
        PreferredConfigOption.save("auto", category: "mode", agentId: "a", defaults)
        PreferredConfigOption.save("opus", category: "model", agentId: "a", defaults)
        PreferredConfigOption.save("high", category: "thought_level", agentId: "a", defaults)
        let options = [
            option("thought_level", id: "effort", current: "low", values: ["low", "high"]),
            option("model", current: "default", values: ["default", "opus"]),
            option("mode", current: "default", values: ["default", "auto"]),
        ]
        let changes = PreferredConfigOption.changes(agentId: "a", options: options, defaults)
        #expect(changes == [
            PreferredConfigChange(optionId: "mode", value: "auto"),
            PreferredConfigChange(optionId: "model", value: "opus"),
            PreferredConfigChange(optionId: "effort", value: "high"),
        ])
    }

    @Test func changesSkipSameUnsupportedAndMissing() throws {
        let name = "oma-test-preferred-config-skip"
        let defaults = try makeDefaults(name)
        defer { defaults.removePersistentDomain(forName: name) }
        PreferredConfigOption.save("opus", category: "model", agentId: "a", defaults)
        PreferredConfigOption.save("max", category: "thought_level", agentId: "a", defaults)
        // 模型已是目标值;思考强度的目标值该引擎不支持;没有模式项
        let options = [
            option("model", current: "opus", values: ["default", "opus"]),
            option("thought_level", current: "low", values: ["low", "high"]),
        ]
        #expect(PreferredConfigOption.changes(agentId: "a", options: options, defaults).isEmpty)
        #expect(PreferredConfigOption.changes(agentId: "b", options: options, defaults).isEmpty)
    }

    @Test func preferredEngineSaveAndClear() throws {
        let name = "oma-test-preferred-engine"
        let defaults = try makeDefaults(name)
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(PreferredEngine.saved(defaults) == nil)
        PreferredEngine.save("goose", defaults)
        #expect(PreferredEngine.saved(defaults) == "goose")
        PreferredEngine.save("", defaults)
        #expect(PreferredEngine.saved(defaults) == nil)
        PreferredEngine.save("goose", defaults)
        PreferredEngine.clear(defaults)
        #expect(PreferredEngine.saved(defaults) == nil)
    }
}
