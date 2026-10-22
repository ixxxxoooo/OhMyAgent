// @author ixxxxoooo
// 终端输出缓冲:把子进程在一帧内到达的大量输出攒起来,按「单帧字节预算」分批喂给 SwiftTerm,
// 避免 `cat` 大文件、编译日志刷屏时 VT 解析一次占满主线程(SwiftTerm 的 `TerminalView` 非线程安全,解析只能留在主线程,所以用预算而不是后台线程)。
// 键入回显等小块输出在缓冲为空时直接喂入,不增加延迟。纯值类型,便于测试。

import Foundation

/// 终端输出缓冲。
struct TerminalOutputBuffer {
    /// 单帧最多喂入的字节数(约 3~5ms 的解析量)
    static let frameBudget = 192 * 1024
    /// 缓冲为空时,不超过该大小的输出直接喂入(保证键入回显零延迟)
    static let directLimit = 16 * 1024

    private var bytes: [UInt8] = []
    private var offset = 0

    /// 缓冲里尚未喂入的字节数
    var pendingCount: Int { bytes.count - offset }
    /// 缓冲是否为空
    var isEmpty: Bool { pendingCount == 0 }

    /// 该块输出是否可以绕过缓冲直接喂入。
    /// - Parameter count: 输出字节数
    func canFeedDirectly(count: Int) -> Bool { isEmpty && count <= Self.directLimit }

    /// 追加输出。
    /// - Parameter slice: 子进程输出
    mutating func append(_ slice: ArraySlice<UInt8>) {
        bytes.append(contentsOf: slice)
    }

    /// 取出下一帧要喂入的数据(不超过预算);取空后释放内存。
    /// - Parameter budget: 本帧字节预算,默认 `frameBudget`;小于 1 时按 1 处理
    /// - Returns: 本帧数据;缓冲为空时为空数组
    mutating func takeFrame(budget: Int = TerminalOutputBuffer.frameBudget) -> ArraySlice<UInt8> {
        guard !isEmpty else { return [] }
        let end = min(offset + max(budget, 1), bytes.count)
        let frame = bytes[offset..<end]
        offset = end
        if offset >= bytes.count {
            bytes.removeAll(keepingCapacity: bytes.count < 1 << 20)
            offset = 0
            return frame
        }
        // 已消费的前缀过大时压缩,避免缓冲无限增长
        if offset > 1 << 20 {
            bytes.removeSubrange(0..<offset)
            offset = 0
            return Array(frame)[...]
        }
        return frame
    }

    /// 丢弃全部未喂入的数据(终端被丢弃时)。
    mutating func removeAll() {
        bytes.removeAll()
        offset = 0
    }
}
