// @author ixxxxoooo
// 提交协作者:用户在设置里维护的一份名单,应用内提交自动追加 `Co-authored-by` 尾注,
// 智能体自己执行 `git commit` 时通过追加系统提示让它同样带上(对照 Cursor 的署名行为)。

import Foundation

/// 一位提交协作者。
public struct CommitCollaborator: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    /// 显示名
    public var name: String
    /// 邮箱
    public var email: String

    /// 创建协作者。
    /// - Parameters:
    ///   - id: 标识(默认随机)
    ///   - name: 显示名
    ///   - email: 邮箱
    public init(id: UUID = UUID(), name: String = "", email: String = "") {
        self.id = id
        self.name = name
        self.email = email
    }

    /// 去掉首尾空白后的名字。
    var cleanName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// 去掉首尾空白后的邮箱。
    var cleanEmail: String { email.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// 是否可用:名字非空且不含会破坏尾注格式的字符,邮箱形如 `a@b.c`。
    public var isValid: Bool {
        let forbidden = CharacterSet(charactersIn: "<>\n\r")
        guard !cleanName.isEmpty, cleanName.rangeOfCharacter(from: forbidden) == nil,
              cleanEmail.range(of: #"^[^\s@<>]+@[^\s@<>]+\.[^\s@<>]+$"#, options: .regularExpression) != nil else { return false }
        return true
    }

    /// 尾注行,如 `Co-authored-by: 张三 <zhangsan@example.com>`;不可用时为 nil。
    public var trailerLine: String? {
        isValid ? "Co-authored-by: \(cleanName) <\(cleanEmail)>" : nil
    }
}

extension CommitCollaborator {
    /// 名单在偏好里的存储格式:JSON 文本(便于 `@AppStorage` 绑定)。
    /// - Parameter list: 名单
    /// - Returns: JSON 文本;编码失败为空串
    public static func encode(_ list: [CommitCollaborator]) -> String {
        guard let data = try? JSONEncoder().encode(list) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// 解析偏好里的名单;空串或损坏时返回空名单。
    /// - Parameter text: JSON 文本
    public static func decode(_ text: String) -> [CommitCollaborator] {
        guard let data = text.data(using: .utf8), !data.isEmpty else { return [] }
        return (try? JSONDecoder().decode([CommitCollaborator].self, from: data)) ?? []
    }

    /// 读取已保存的名单。
    /// - Parameter defaults: 偏好存储
    public static func saved(_ defaults: UserDefaults = .standard) -> [CommitCollaborator] {
        decode(defaults.string(forKey: ClientPrefs.Key.scmCollaborators) ?? "")
    }

    /// 名单里可用的尾注行(按邮箱去重,保持顺序)。
    /// - Parameter list: 名单
    public static func trailerLines(_ list: [CommitCollaborator]) -> [String] {
        var seen = Set<String>()
        return list.compactMap { item in
            guard let line = item.trailerLine, seen.insert(item.cleanEmail.lowercased()).inserted else { return nil }
            return line
        }
    }

    /// 追加给智能体的系统提示:让它自己执行 `git commit` 时也带上协作者尾注。
    /// - Parameter list: 名单
    /// - Returns: 提示文本;没有可用协作者时为 nil
    public static func agentPrompt(_ list: [CommitCollaborator]) -> String? {
        let lines = trailerLines(list)
        guard !lines.isEmpty else { return nil }
        return "通过 git commit 提交代码时,请在提交说明末尾(与正文空一行,已有尾注则紧接其后)追加下列协作者尾注,每人一行,已存在则不要重复:\n"
            + lines.joined(separator: "\n")
    }
}
