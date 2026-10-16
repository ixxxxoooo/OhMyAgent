// @author ixxxxoooo
// 拖入/粘贴到输入框的文件分流:图片进附件,其余文件与文件夹转成 `@路径` 提及。
// 纯函数,便于测试;不读取文件内容,只看扩展名与是否为目录。

import Foundation

/// 被拖入项的类别。
public enum DroppedKind: Equatable, Sendable {
    case image, file, directory
}

/// 被拖入的一项。
public struct DroppedItem: Equatable, Sendable {
    public let url: URL
    public let kind: DroppedKind

    public init(url: URL, kind: DroppedKind) {
        self.url = url
        self.kind = kind
    }
}

/// 拖入分流与 `@路径` 文本生成。
public enum DropClassifier {
    /// 视为图片(进附件缩略图条)的扩展名。
    public static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp"]

    /// 对文件 URL 分类并去重(按标准化路径);非文件 URL 被忽略。
    /// - Parameter urls: 拖入的 URL
    /// - Returns: 按出现顺序的分类结果
    public static func classify(_ urls: [URL]) -> [DroppedItem] {
        var seen = Set<String>()
        var result: [DroppedItem] = []
        for url in urls where url.isFileURL {
            let path = url.standardizedFileURL.path
            guard !path.isEmpty, seen.insert(path).inserted else { continue }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                result.append(DroppedItem(url: url.standardizedFileURL, kind: .directory))
            } else if imageExtensions.contains(url.pathExtension.lowercased()) {
                result.append(DroppedItem(url: url.standardizedFileURL, kind: .image))
            } else {
                result.append(DroppedItem(url: url.standardizedFileURL, kind: .file))
            }
        }
        return result
    }

    /// 生成单个 `@路径` 文本:工作区内用相对路径,否则绝对路径;含空白时加引号 `@"…"`;目录以 `/` 结尾。
    /// - Parameters:
    ///   - item: 被拖入的文件或文件夹
    ///   - workspace: 工作区目录
    /// - Returns: 如 `@Sources/App.swift`、`@"my docs/a b.txt"`
    public static func mentionText(for item: DroppedItem, workspace: URL) -> String {
        let root = workspace.standardizedFileURL.path
        let path = item.url.standardizedFileURL.path
        var text: String
        if path == root {
            text = "."
        } else if path.hasPrefix(root.hasSuffix("/") ? root : root + "/") {
            text = String(path.dropFirst(root.hasSuffix("/") ? root.count : root.count + 1))
        } else {
            text = path
        }
        if item.kind == .directory, !text.hasSuffix("/") { text += "/" }
        if text.contains(where: { $0.isWhitespace }) { return "@\"\(text)\"" }
        return "@" + text
    }

    /// 把所有非图片项拼成一段以空格分隔、末尾带空格的提及文本;没有可提及项时返回空串。
    public static func mentions(for items: [DroppedItem], workspace: URL) -> String {
        let parts = items.filter { $0.kind != .image }.map { mentionText(for: $0, workspace: workspace) }
        return parts.isEmpty ? "" : parts.joined(separator: " ") + " "
    }
}
