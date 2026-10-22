// @author ixxxxoooo
// 融合模式开关:开启后 Agent 窗口与 IDE 窗口原地互切(同一外框、同一项目、共用同一份会话)。
// 值落在 UserDefaults(键 `ClientPrefs.Key.fusionMode`),并以 Observation 暴露,
// 设置页切换后 IDE 面板、标题栏等立即随之刷新。

import ChatKit
import Foundation
import Observation

@MainActor
@Observable
final class FusionMode {
    static let shared = FusionMode()

    /// 是否开启融合模式(写入时同步落盘)。
    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: ClientPrefs.Key.fusionMode)
        }
    }

    @ObservationIgnored private let defaults: UserDefaults

    /// - Parameter defaults: 偏好存储(测试可注入独立实例)
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: ClientPrefs.Key.fusionMode)
    }

    /// 重新读取偏好(「重置所有客户端设置」删除键之后调用)。
    func reload() {
        isEnabled = defaults.bool(forKey: ClientPrefs.Key.fusionMode)
    }
}
