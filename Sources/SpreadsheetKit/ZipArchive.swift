// @author ixxxxoooo
// 只读 ZIP 解包:读取中央目录并按名称取出条目(支持存储与 deflate 两种方式)。
// xlsx 本质是 ZIP;这里不依赖任何第三方库,deflate 用系统 Compression 框架(COMPRESSION_ZLIB 即原始 deflate 流)。

import Compression
import Foundation

/// ZIP 解包错误。
public enum ZipError: Error, Equatable, LocalizedError {
    case notAZip
    case unsupported(String)
    case entryNotFound(String)
    case corrupted(String)

    public var errorDescription: String? {
        switch self {
        case .notAZip: return String(localized: "不是有效的 ZIP/xlsx 文件")
        case .unsupported(let what): return String(localized: "暂不支持:\(what)")
        case .entryNotFound(let name): return String(localized: "文件中缺少 \(name)")
        case .corrupted(let what): return String(localized: "文件已损坏:\(what)")
        }
    }
}

/// 内存中的 ZIP 归档(只读)。
public struct ZipArchive: Sendable {
    /// 中央目录里的一个条目。
    struct Entry: Sendable {
        let name: String
        let method: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    private let data: Data
    private let entries: [String: Entry]

    /// 单个条目解压后的大小上限(防止恶意压缩炸弹)。
    public static let maxEntrySize = 512 * 1024 * 1024

    /// 条目名称集合。
    public var names: [String] { Array(entries.keys) }

    /// - Parameter data: 整个 ZIP 文件内容
    /// - Throws: `ZipError`
    public init(data: Data) throws {
        let bytes = Data(data)   // 保证索引从 0 开始
        self.data = bytes
        guard bytes.count >= 22 else { throw ZipError.notAZip }
        // 结束记录(EOCD)在文件尾部,最多带 64KB 注释
        let lowerBound = max(0, bytes.count - 22 - 65_535)
        var eocd = -1
        var index = bytes.count - 22
        while index >= lowerBound {
            if Self.u32(bytes, index) == 0x0605_4B50 { eocd = index; break }
            index -= 1
        }
        guard eocd >= 0 else { throw ZipError.notAZip }
        let count = Int(Self.u16(bytes, eocd + 10))
        let directorySize = Int(Self.u32(bytes, eocd + 12))
        let directoryOffset = Int(Self.u32(bytes, eocd + 16))
        if count == 0xFFFF || directoryOffset == 0xFFFF_FFFF || directorySize == 0xFFFF_FFFF { throw ZipError.unsupported("ZIP64") }
        guard directoryOffset >= 0, directoryOffset + directorySize <= bytes.count else { throw ZipError.corrupted("central directory out of range") }

        var result: [String: Entry] = [:]
        var cursor = directoryOffset
        for _ in 0..<count {
            guard cursor + 46 <= bytes.count, Self.u32(bytes, cursor) == 0x0201_4B50 else { throw ZipError.corrupted("central directory entry") }
            let flags = Self.u16(bytes, cursor + 8)
            let method = Self.u16(bytes, cursor + 10)
            let compressed = Int(Self.u32(bytes, cursor + 20))
            let uncompressed = Int(Self.u32(bytes, cursor + 24))
            let nameLength = Int(Self.u16(bytes, cursor + 28))
            let extraLength = Int(Self.u16(bytes, cursor + 30))
            let commentLength = Int(Self.u16(bytes, cursor + 32))
            let offset = Int(Self.u32(bytes, cursor + 42))
            guard cursor + 46 + nameLength <= bytes.count else { throw ZipError.corrupted("entry name out of range") }
            if flags & 0x1 != 0 { throw ZipError.unsupported(String(localized: "加密的文件")) }
            let nameData = bytes.subdata(in: (cursor + 46)..<(cursor + 46 + nameLength))
            let name = String(data: nameData, encoding: .utf8) ?? String(decoding: nameData, as: UTF8.self)
            result[name] = Entry(name: name, method: method, compressedSize: compressed, uncompressedSize: uncompressed, localHeaderOffset: offset)
            cursor += 46 + nameLength + extraLength + commentLength
        }
        entries = result
    }

    /// 条目是否存在。
    public func contains(_ name: String) -> Bool { entries[name] != nil }

    /// 读取并解压一个条目。
    /// - Parameter name: 条目路径(如 `xl/workbook.xml`)
    /// - Returns: 解压后的内容
    /// - Throws: `ZipError`
    public func read(_ name: String) throws -> Data {
        guard let entry = entries[name] else { throw ZipError.entryNotFound(name) }
        guard entry.uncompressedSize <= Self.maxEntrySize else { throw ZipError.unsupported(String(localized: "条目过大")) }
        let header = entry.localHeaderOffset
        guard header >= 0, header + 30 <= data.count, Self.u32(data, header) == 0x0403_4B50 else { throw ZipError.corrupted(name) }
        let start = header + 30 + Int(Self.u16(data, header + 26)) + Int(Self.u16(data, header + 28))
        let end = start + entry.compressedSize
        guard start >= 0, end <= data.count else { throw ZipError.corrupted(name) }
        let raw = data.subdata(in: start..<end)
        switch entry.method {
        case 0:
            return raw
        case 8:
            return try Self.inflate(raw, expectedSize: entry.uncompressedSize, name: name)
        default:
            throw ZipError.unsupported("compression method \(entry.method)")
        }
    }

    /// 解压原始 deflate 数据。
    private static func inflate(_ input: Data, expectedSize: Int, name: String) throws -> Data {
        if expectedSize == 0 { return Data() }
        var output = Data(count: expectedSize)
        let written = output.withUnsafeMutableBytes { (out: UnsafeMutableRawBufferPointer) -> Int in
            input.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
                guard let outBase = out.bindMemory(to: UInt8.self).baseAddress, let srcBase = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(outBase, expectedSize, srcBase, input.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == expectedSize else { throw ZipError.corrupted("\(name) inflate failed") }
        return output
    }

    // MARK: 小端读取

    private static func u16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset]) | UInt32(data[offset + 1]) << 8 | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
    }
}
