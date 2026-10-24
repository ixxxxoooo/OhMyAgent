// @author ixxxxoooo
// 存活的编辑器视图实例计数(泄漏测试用)。

import Synchronization

/// 存活的编辑器实例计数(全局原子量:`deinit` 非隔离,不能碰主 actor 静态属性)。
/// TextKit 与原生编辑器视图共用同一计数,保证泄漏测试对两种引擎都有效。
let editorLiveCounter = Atomic<Int>(0)
