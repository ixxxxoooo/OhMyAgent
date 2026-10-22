// @author ixxxxoooo
// 融合模式开关测试:默认关闭、写入落盘、重新读取与重置。

import ChatKit
import Foundation
import Testing
@testable import OhMyAgentApp

@MainActor
@Suite("融合模式开关")
struct FusionModeTests {
    private func makeDefaults() -> UserDefaults {
        let name = "oma-fusion-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name) ?? .standard
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("默认关闭;开启后写入偏好,新实例读到同样的值")
    func persists() {
        let defaults = makeDefaults()
        let mode = FusionMode(defaults: defaults)
        #expect(mode.isEnabled == false)
        mode.isEnabled = true
        #expect(defaults.bool(forKey: ClientPrefs.Key.fusionMode))
        #expect(FusionMode(defaults: defaults).isEnabled)
    }

    @Test("重置偏好后 reload 回到关闭")
    func reloadAfterReset() {
        let defaults = makeDefaults()
        let mode = FusionMode(defaults: defaults)
        mode.isEnabled = true
        ClientPrefs.resetAll(defaults)
        mode.reload()
        #expect(mode.isEnabled == false)
    }
}
