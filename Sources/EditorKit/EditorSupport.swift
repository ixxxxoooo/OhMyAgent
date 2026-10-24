// @author ixxxxoooo
// 编辑器共用的小工具:存活实例计数(泄漏测试用)、`Duration.seconds`。

import Foundation
import Synchronization

/// 存活的编辑器实例计数(全局原子量:`deinit` 非隔离,不能碰主 actor 静态属性)。
let editorLiveCounter = Atomic<Int>(0)

public extension Duration {
    /// 转换为秒(基准与诊断代码计时用)。
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
