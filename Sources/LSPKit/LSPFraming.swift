// @author ixxxxoooo
// LSP 基础协议分帧:`Content-Length: N\r\n\r\n` + N 字节 JSON 正文。

import Foundation

/// LSP 帧解码器:处理被拆分到多次读取中的头部与正文,正文长度按**字节**计算。
public struct LSPFrameDecoder: Sendable {
    private var buffer = Data()
    /// 单帧正文上限,超过视为异常数据并丢弃缓冲,防止内存被撑爆。
    public let maxBodyLength: Int
    /// 因头部非法而丢弃的次数(用于诊断)。
    public private(set) var droppedCount = 0

    /// - Parameter maxBodyLength: 单帧正文上限(字节),默认 64 MB
    public init(maxBodyLength: Int = 64 * 1024 * 1024) {
        self.maxBodyLength = maxBodyLength
    }

    private static let separator = Data("\r\n\r\n".utf8)

    /// 喂入新数据并取出所有完整帧的正文。
    /// - Parameter chunk: 新读取到的字节
    /// - Returns: 完整帧的 JSON 正文数组
    public mutating func push(_ chunk: Data) -> [Data] {
        buffer.append(chunk)
        var bodies: [Data] = []
        while true {
            guard let headerEnd = buffer.range(of: Self.separator) else {
                // 头部尚未收全;头部不可能无限长
                if buffer.count > 16 * 1024 { buffer.removeAll(); droppedCount += 1 }
                break
            }
            let headerData = buffer[buffer.startIndex..<headerEnd.lowerBound]
            guard let length = Self.contentLength(in: headerData), length >= 0, length <= maxBodyLength else {
                // 头部非法:丢弃已读的这一段头部,尝试在剩余数据中继续同步
                buffer.removeSubrange(buffer.startIndex..<headerEnd.upperBound)
                droppedCount += 1
                continue
            }
            let bodyStart = headerEnd.upperBound
            guard buffer.count - (bodyStart - buffer.startIndex) >= length else { break }
            let bodyEnd = buffer.index(bodyStart, offsetBy: length)
            bodies.append(Data(buffer[bodyStart..<bodyEnd]))
            buffer.removeSubrange(buffer.startIndex..<bodyEnd)
        }
        return bodies
    }

    /// 从头部文本解析 `Content-Length`(忽略大小写与其它头部)。
    private static func contentLength(in header: Data) -> Int? {
        guard let text = String(data: header, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\r\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" else { continue }
            return Int(parts[1].trimmingCharacters(in: .whitespaces))
        }
        return nil
    }
}

/// LSP 帧编码。
public enum LSPFrameEncoder {
    /// 给 JSON 正文加上 `Content-Length` 头部。
    /// - Parameter body: JSON 正文(UTF-8)
    /// - Returns: 可直接写入服务器 stdin 的完整帧
    public static func encode(_ body: Data) -> Data {
        var frame = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        frame.append(body)
        return frame
    }
}
