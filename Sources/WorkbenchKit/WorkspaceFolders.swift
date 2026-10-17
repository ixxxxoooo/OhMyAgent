// @author ixxxxoooo
// 多文件夹工作区:校验与规范化附加文件夹(纯逻辑,无 UI)。

import Foundation

/// 添加附加文件夹失败的原因。
public enum WorkspaceFolderError: Error, Equatable, Sendable {
    /// 路径不存在或不是目录
    case notDirectory
    /// 已经是工作区的一员(主目录或已添加)
    case duplicate
    /// 位于工作区已有文件夹之内(已被覆盖)
    case insideExisting(String)
    /// 包含工作区已有的文件夹(会造成重复索引)
    case containsExisting(String)
    /// 超过上限
    case tooMany

    /// 面向用户的说明(中文,经本地化)。
    public var message: String {
        switch self {
        case .notDirectory: String(localized: "只能添加已存在的文件夹。")
        case .duplicate: String(localized: "这个文件夹已经在工作区里了。")
        case .insideExisting(let path): String(localized: "它位于工作区已有的文件夹 \(path) 之内,已被覆盖。")
        case .containsExisting(let path): String(localized: "它包含工作区已有的文件夹 \(path),请先移除后再添加。")
        case .tooMany: String(localized: "一个工作区最多包含 \(WorkspaceFolders.maxExtraFolders) 个附加文件夹。")
        }
    }
}

/// 附加文件夹规则。
public enum WorkspaceFolders {
    /// 附加文件夹数量上限(避免索引与监听失控)
    public static let maxExtraFolders = 8

    /// 规范化路径:标准化、去掉末尾斜杠。
    /// - Parameter path: 任意路径
    /// - Returns: 规范化后的绝对路径
    public static func normalize(_ path: String) -> String {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        return standardized.count > 1 && standardized.hasSuffix("/") ? String(standardized.dropLast()) : standardized
    }

    /// `child` 是否位于 `parent` 之内(或相同)。
    /// - Parameters:
    ///   - child: 子路径
    ///   - parent: 父路径
    public static func isInside(_ child: String, of parent: String) -> Bool {
        child == parent || child.hasPrefix(parent == "/" ? "/" : parent + "/")
    }

    /// 校验并规范化要添加的文件夹。
    /// - Parameters:
    ///   - path: 候选文件夹路径
    ///   - primary: 工作区主目录
    ///   - existing: 已添加的附加文件夹
    ///   - requireExists: 是否要求目录真实存在(测试可关闭)
    /// - Returns: 成功得到规范化路径;失败给出原因
    public static func validate(_ path: String, primary: String, existing: [String], requireExists: Bool = true) -> Result<String, WorkspaceFolderError> {
        let normalized = normalize(path)
        if requireExists {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: normalized, isDirectory: &isDirectory), isDirectory.boolValue else {
                return .failure(.notDirectory)
            }
        }
        let roots = [primary] + existing
        if roots.contains(normalized) { return .failure(.duplicate) }
        if existing.count >= maxExtraFolders { return .failure(.tooMany) }
        if let outer = roots.first(where: { isInside(normalized, of: $0) }) { return .failure(.insideExisting((outer as NSString).lastPathComponent)) }
        if let inner = roots.first(where: { isInside($0, of: normalized) }) { return .failure(.containsExisting((inner as NSString).lastPathComponent)) }
        return .success(normalized)
    }
}

extension ProjectEntry {
    /// 工作区的全部根目录:主目录在前,附加文件夹按添加顺序。
    public var allRoots: [String] { [id] + extraFolders }

    /// 是否是多文件夹工作区。
    public var isMultiRoot: Bool { !extraFolders.isEmpty }
}
