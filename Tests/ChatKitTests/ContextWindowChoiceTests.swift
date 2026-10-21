// @author ixxxxoooo
import Foundation
import Testing
@testable import ChatKit

@Suite("上下文窗口档位")
struct ContextWindowChoiceTests {
    @Test("标题:默认、K、M")
    func titles() {
        #expect(ContextWindowChoice.title(for: 200_000) == "200K")
        #expect(ContextWindowChoice.title(for: 1_000_000) == "1M")
        #expect(ContextWindowChoice.title(for: 0) == String(localized: "默认"))
    }

    @Test("归一:负数为默认,其余夹到允许范围")
    func normalize() {
        #expect(ContextWindowChoice.normalized(-5) == 0)
        #expect(ContextWindowChoice.normalized(10_000) == SessionOptions.autoCompactRange.lowerBound)
        #expect(ContextWindowChoice.normalized(5_000_000) == SessionOptions.autoCompactRange.upperBound)
        #expect(ContextWindowChoice.normalized(300_000) == 300_000)
    }

    @Test("预设档位都在有效范围内且递增")
    func presetsValid() {
        let real = ContextWindowChoice.presets.filter { $0 > 0 }
        #expect(real == real.sorted())
        #expect(real.allSatisfy { SessionOptions.autoCompactRange.contains($0) })
        #expect(ContextWindowChoice.presets.first == 0)
    }
}

@Suite("按模型记忆上下文窗口")
struct ModelContextWindowStorageTests {
    @Test("写入并清除某个模型的窗口,其他模型不受影响")
    func setAndClear() throws {
        let dir = try ModelProviderTests.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var provider = ModelProviderTests.deepseek
        provider.models = [ProviderModel(id: "a"), ProviderModel(id: "b", contextWindow: 200_000)]
        try ProviderStorage.save(ProviderSnapshot(mapping: ModelMapping(slots: [.main: ModelTarget(providerId: provider.id, model: "a")]), providers: [provider]), directory: dir)

        try ProviderStorage.setModelContextWindow(1_000_000, model: "a", providerId: provider.id, directory: dir)
        var models = ProviderStorage.load(directory: dir).providers[0].modelList
        #expect(models.first { $0.id == "a" }?.contextWindow == 1_000_000)
        #expect(models.first { $0.id == "b" }?.contextWindow == 200_000)
        // 快照里的 MappedModel 带上模型级窗口
        #expect(ProviderStorage.configuredInfos(directory: dir)[.main]?.contextWindow == 1_000_000)

        try ProviderStorage.setModelContextWindow(nil, model: "a", providerId: provider.id, directory: dir)
        models = ProviderStorage.load(directory: dir).providers[0].modelList
        #expect(models.first { $0.id == "a" }?.contextWindow == nil)
    }

    @Test("未登记的模型会新增条目;未知提供商静默忽略")
    func unknownModelAndProvider() throws {
        let dir = try ModelProviderTests.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let provider = ModelProviderTests.deepseek
        try ProviderStorage.save(ProviderSnapshot(mapping: ModelMapping(), providers: [provider]), directory: dir)
        try ProviderStorage.setModelContextWindow(300_000, model: "new-model", providerId: provider.id, directory: dir)
        #expect(ProviderStorage.load(directory: dir).providers[0].modelList.first { $0.id == "new-model" }?.contextWindow == 300_000)
        try ProviderStorage.setModelContextWindow(300_000, model: "x", providerId: "nope", directory: dir)
    }
}
