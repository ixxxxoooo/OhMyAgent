// @author ixxxxoooo
import ChatKit
import Foundation
import Testing

@Suite("字体平滑偏好")
struct FontSmoothingTests {
    private func makeDefaults() -> UserDefaults {
        let suite = "oma.test.fontSmoothing.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test("档位映射到 AppleFontSmoothing 数值,跟随系统为 nil")
    func values() {
        #expect(FontSmoothing.system.appleValue == nil)
        #expect(FontSmoothing.allCases.compactMap(\.appleValue) == [0, 1, 2, 3])
    }

    @Test("非法偏好回退跟随系统")
    func invalid() {
        let defaults = makeDefaults()
        defaults.set("乱写", forKey: FontSmoothing.preferenceKey)
        #expect(FontSmoothing.current(defaults) == .system)
    }

    @Test("启动应用:写入或移除 AppleFontSmoothing")
    func apply() {
        let defaults = makeDefaults()
        defaults.set(FontSmoothing.strong.rawValue, forKey: FontSmoothing.preferenceKey)
        FontSmoothing.applyAtLaunch(defaults)
        #expect(defaults.integer(forKey: FontSmoothing.appleKey) == 3)
        defaults.set(FontSmoothing.system.rawValue, forKey: FontSmoothing.preferenceKey)
        FontSmoothing.applyAtLaunch(defaults)
        #expect(defaults.object(forKey: FontSmoothing.appleKey) == nil)
    }
}
