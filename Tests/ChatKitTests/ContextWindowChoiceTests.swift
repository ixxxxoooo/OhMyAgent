// @author ixxxxoooo
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
