// @author ixxxxoooo
// 会话真实创建时间解析器:从文件系统或条目元数据中解析会话的真实物理创建时间。

import Foundation

/// 会话物理与逻辑创建时间解析器。
public enum SessionTimeResolver {
    /// 尝试从本地磁盘获取会话记录文件的物理创建时间(birthtime)。
    /// - Parameters:
    ///   - sessionId: 协议会话 ID
    ///   - projectPath: 项目根目录绝对路径
    ///   - agentID: 该会话所属 Agent ID(如 "claude-code", "antigravity" 等)
    /// - Returns: 文件系统上的真实创建时间,若不存在则为 nil
    public static func resolvePhysicalCreationDate(
        sessionId: String,
        projectPath: String,
        agentID: String? = nil
    ) -> Date? {
        guard !sessionId.isEmpty else { return nil }
        let home = NSHomeDirectory()
        let fm = FileManager.default

        // 1. Claude Code: ~/.claude/projects/-path-to-project/<sessionId>.jsonl
        let safeProj = projectPath.replacingOccurrences(of: "/", with: "-")
        let claudeCandidates = [
            "\(home)/.claude/projects/\(safeProj)/\(sessionId).jsonl",
            "\(home)/.claude/projects/\(safeProj.trimmingCharacters(in: CharacterSet(charactersIn: "-")))/\(sessionId).jsonl"
        ]
        for path in claudeCandidates {
            if let date = creationDate(of: path, fileManager: fm) { return date }
        }

        // 2. Antigravity ACP 与原生:
        let agyCandidates = [
            "\(home)/.gemini/antigravity-acp/conversations/\(sessionId).db",
            "\(home)/.gemini/antigravity-acp/conversations/\(sessionId).meta",
            "\(home)/.gemini/antigravity/conversations/\(sessionId).db",
            "\(home)/.gemini/antigravity/conversations/\(sessionId).pb",
            "\(home)/.gemini/antigravity/brain/\(sessionId)"
        ]
        for path in agyCandidates {
            if let date = creationDate(of: path, fileManager: fm) { return date }
        }

        return nil
    }

    /// 读取指定路径文件的创建时间。
    private static func creationDate(of path: String, fileManager: FileManager) -> Date? {
        guard fileManager.fileExists(atPath: path) else { return nil }
        guard let attrs = try? fileManager.attributesOfItem(atPath: path) else { return nil }
        return attrs[.creationDate] as? Date
    }
}
