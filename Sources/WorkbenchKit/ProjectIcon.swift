// @author ixxxxoooo
// 项目图标:可以是 Lucide 功能图标、一个表情,或用户导入的图片(复制到应用支持目录,不引用原文件)。

import Foundation

/// 项目在侧栏中的自定义图标。
public struct ProjectIcon: Codable, Equatable, Sendable {
    /// 图标类型。
    public enum Kind: String, Codable, Sendable {
        /// Lucide 语义名
        case symbol
        /// 单个表情字符
        case emoji
        /// 导入的图片(`value` 为图标目录下的文件名)
        case image
    }

    public var kind: Kind
    /// 符号名 / 表情 / 图片文件名
    public var value: String

    public init(kind: Kind, value: String) {
        self.kind = kind
        self.value = value
    }

    /// 构造 Lucide 图标。
    /// - Returns: 名称为空返回 nil
    public static func symbol(_ name: String) -> ProjectIcon? {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : ProjectIcon(kind: .symbol, value: clean)
    }

    /// 构造表情图标:只取输入的第一个字符(含组合表情),忽略空白。
    /// - Returns: 没有可用字符返回 nil
    public static func emoji(_ text: String) -> ProjectIcon? {
        guard let first = text.trimmingCharacters(in: .whitespacesAndNewlines).first else { return nil }
        return ProjectIcon(kind: .emoji, value: String(first))
    }
}

/// 图标图片的存取。
public enum ProjectIconFiles {
    /// 允许导入的图片大小上限(10 MB)。
    public static let maxImageBytes = 10_000_000
    /// 允许的扩展名。
    public static let allowedExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "tiff", "webp", "icns"]

    /// 把图片复制进图标目录,返回新的图片图标。
    /// - Parameters:
    ///   - source: 用户选择的图片
    ///   - directory: 图标目录(不存在会创建)
    /// - Returns: 成功返回图标;不是图片、过大或复制失败返回 nil
    public static func importImage(from source: URL, into directory: URL) -> ProjectIcon? {
        let ext = source.pathExtension.lowercased()
        guard allowedExtensions.contains(ext) else { return nil }
        let size = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 0, size <= maxImageBytes else { return nil }
        let name = UUID().uuidString + "." + ext
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: directory.appendingPathComponent(name))
            return ProjectIcon(kind: .image, value: name)
        } catch {
            return nil
        }
    }

    /// 图片图标的文件地址。
    /// - Returns: 非图片图标或文件不存在返回 nil
    public static func fileURL(for icon: ProjectIcon, in directory: URL) -> URL? {
        guard icon.kind == .image, !icon.value.contains("/") else { return nil }
        let url = directory.appendingPathComponent(icon.value)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// 删除图片图标对应的文件(其他类型忽略)。
    public static func removeFile(for icon: ProjectIcon?, in directory: URL) {
        guard let icon, icon.kind == .image, !icon.value.contains("/") else { return }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(icon.value))
    }
}
