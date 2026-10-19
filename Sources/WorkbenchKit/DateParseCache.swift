// @author ixxxxoooo
// ISO8601 时间解析的记忆化:侧栏每次重算都要对每个缓存会话解析 2~6 次(含毫秒/不含毫秒双策略,最多 400 条/项目),
// 而这些字符串落盘后恒定不变,按字符串缓存结果即可把重复解析降为一次字典查找。

import Foundation
import os

/// 线程安全、容量有界的 ISO8601 解析缓存(含解析失败的结果,避免对非法串反复重试)。
enum DateParseCache {
    /// 缓存条目上限:超过后整体清空重建(会话数量级为几百到几千,足够)。
    static let capacity = 8192

    private struct Storage {
        var table: [String: Date?] = [:]
        var parses = 0
    }

    private static let storage = OSAllocatedUnfairLock(initialState: Storage())

    /// 解析并记忆。
    /// - Parameter text: ISO8601 字符串(含/不含毫秒)
    /// - Returns: 日期;无法解析返回 nil
    static func date(for text: String) -> Date? {
        if let cached = storage.withLock({ $0.table[text] }) { return cached }
        let parsed = (try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
            ?? (try? Date(text, strategy: Date.ISO8601FormatStyle()))
        storage.withLock { state in
            if state.table.count >= capacity { state.table.removeAll(keepingCapacity: true) }
            state.table[text] = .some(parsed)
            state.parses += 1
        }
        return parsed
    }

    /// 实际解析次数(测试用:验证重复读取命中缓存)。
    static var parseCount: Int { storage.withLock { $0.parses } }

    /// 清空(测试用)。
    static func reset() { storage.withLock { $0 = Storage() } }
}
