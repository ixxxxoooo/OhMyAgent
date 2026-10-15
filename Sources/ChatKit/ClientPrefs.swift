// @author ygw
// 客户端偏好(UserDefaults):仅属于 OhMyAgent 本身的设置。Claude Code 自身的设置写回 settings.json,不在此处。
// 设置页用 @AppStorage 绑定同名键,业务代码用这里的静态访问器读取,因此修改立即生效。

import Foundation

/// 客户端偏好键与读取器。
public enum ClientPrefs {
    public enum Key {
        public static let restoreWindows = "general.restoreWindows"
        public static let showDock = "general.showDock"
        public static let showMenuBar = "general.showMenuBar"
        public static let autoUpdate = "update.auto"
        public static let updateChannel = "update.channel"
        public static let updateFeedURL = "update.feedURL"
        public static let updateLastCheck = "update.lastCheck"
        public static let editorFontSize = "editor.fontSize"
        public static let editorWrap = "editor.wrap"
        public static let editorLargeFileLines = "editor.largeFileLines"
        public static let terminalFontSize = "terminal.fontSize"
        public static let terminalOutputKB = "terminal.outputLimitKB"
        public static let terminalInheritEnv = "terminal.inheritEnvironment"
        public static let budgetUSD = "usage.budgetUSD"
        public static let redactLogs = "privacy.redactLogs"
        public static let pathNode = "advanced.path.node"
        public static let pathClaude = "advanced.path.claude"
        public static let pathAdapter = "advanced.path.adapter"
        public static let featureFileSystem = "feature.fileSystem"
        public static let featureTerminal = "feature.terminal"
        public static let featureElicitation = "feature.elicitation"
    }

    /// 终端输出缓冲上限(字节),默认 1 MB,范围 64 KB–16 MB。
    public static func terminalOutputLimit(_ defaults: UserDefaults = .standard) -> Int {
        let kb = defaults.object(forKey: Key.terminalOutputKB) as? Int ?? 1024
        return min(max(kb, 64), 16_384) * 1024
    }

    /// 终端是否继承完整登录 shell 环境。
    public static func terminalInheritsEnvironment(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: Key.terminalInheritEnv) as? Bool ?? true
    }

    /// 终端不继承完整环境时保留的变量。
    static let minimalEnvironmentKeys: Set<String> = ["PATH", "HOME", "USER", "LOGNAME", "SHELL", "LANG", "LC_ALL", "TERM", "TMPDIR"]

    /// 按偏好过滤终端环境。
    /// - Parameters:
    ///   - environment: 登录 shell 环境
    ///   - inherit: 是否完整继承
    public static func filterTerminalEnvironment(_ environment: [String: String], inherit: Bool) -> [String: String] {
        inherit ? environment : environment.filter { minimalEnvironmentKeys.contains($0.key) }
    }

    /// 工具路径覆盖(空串视为未设置)。
    public static func pathOverrides(_ defaults: UserDefaults = .standard) -> [String: String] {
        var result: [String: String] = [:]
        for (name, key) in [("node", Key.pathNode), ("claude", Key.pathClaude), ("adapter", Key.pathAdapter)] {
            if let value = defaults.string(forKey: key)?.trimmingCharacters(in: .whitespaces), !value.isEmpty { result[name] = value }
        }
        return result
    }

    /// 预算提醒阈值(美元);0 表示关闭。
    public static func budgetUSD(_ defaults: UserDefaults = .standard) -> Double {
        max(defaults.double(forKey: Key.budgetUSD), 0)
    }

    /// 删除全部客户端偏好(不含 Claude 设置)。
    public static func resetAll(_ defaults: UserDefaults = .standard) {
        for key in defaults.dictionaryRepresentation().keys {
            let prefixes = ["general.", "update.", "editor.", "terminal.", "usage.", "privacy.", "advanced.", "feature.", "appearance.", "shortcut."]
            if prefixes.contains(where: { key.hasPrefix($0) }) { defaults.removeObject(forKey: key) }
        }
    }
}
