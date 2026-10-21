// @author ixxxxoooo
// IDE 自动保存策略(I12):默认关闭、非法值回退、三种模式往返。

import Foundation
import Testing
@testable import IDEKit

@Suite("IDE 自动保存策略", .serialized)
struct IDEAutoSaveTests {
    private let defaults = UserDefaults.standard

    @Test("缺省与非法值回退为关闭,合法值往返")
    func roundTrip() {
        let saved = defaults.object(forKey: IDEAutoSaveMode.key)
        defer { if let saved { defaults.set(saved, forKey: IDEAutoSaveMode.key) } else { defaults.removeObject(forKey: IDEAutoSaveMode.key) } }
        defaults.removeObject(forKey: IDEAutoSaveMode.key)
        #expect(IDEAutoSaveMode.current == .off)
        defaults.set("乱写", forKey: IDEAutoSaveMode.key)
        #expect(IDEAutoSaveMode.current == .off)
        for mode in IDEAutoSaveMode.allCases {
            defaults.set(mode.rawValue, forKey: IDEAutoSaveMode.key)
            #expect(IDEAutoSaveMode.current == mode)
        }
        #expect(IDEAutoSaveMode.delay == .seconds(1))
    }
}
