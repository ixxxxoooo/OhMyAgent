// @author ixxxxoooo
// 定位 `claude` 命令行工具(原生适配器直接驱动它,不再需要 Node 与外部适配器)。

import Foundation
import OMLog

/// 定位结果。
public struct LocatedTools: Sendable, Hashable {
    public var claudePath: String?
    /// 用于启动子进程的环境(已合并登录 shell 环境)
    public var environment: [String: String]

    /// 是否具备以 ACP 方式启动 Claude Code 的全部条件。
    public var isACPReady: Bool { claudePath != nil }

    public init(claudePath: String? = nil, environment: [String: String]) {
        self.claudePath = claudePath
        self.environment = environment
    }
}

/// 可执行文件定位器。
public enum ExecutableLocator {
    /// 按优先级探测工具。
    /// - Parameters:
    ///   - overrides: 用户在「高级」设置中指定的路径(键:claude)
    ///   - environment: 已解析的登录 shell 环境
    /// - Returns: 定位结果
    public static func locate(overrides: [String: String] = [:], environment: [String: String]) -> LocatedTools {
        let fm = FileManager.default
        let pathDirs = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let home = environment["HOME"] ?? NSHomeDirectory()
        var claudeCandidates: [String] = []
        if let value = overrides["claude"], !value.isEmpty { claudeCandidates.append(value) }
        claudeCandidates += pathDirs.map { "\($0)/claude" }
        claudeCandidates += ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        let claudePath = claudeCandidates.first { fm.isExecutableFile(atPath: $0) }
        return LocatedTools(claudePath: claudePath, environment: environment)
    }
}
