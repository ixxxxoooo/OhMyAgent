// @author ixxxxoooo
// 客户端偏好(UserDefaults):仅属于 OhMyAgent 本身的设置。Claude Code 自身的设置写回 settings.json,不在此处。
// 设置页用 @AppStorage 绑定同名键,业务代码用这里的静态访问器读取,因此修改立即生效。

import AgentHost
import Foundation

/// 客户端偏好键与读取器。
public enum ClientPrefs {
    public enum Key {
        public static let restoreWindows = "general.restoreWindows"
        public static let showDock = "general.showDock"
        public static let showMenuBar = "general.showMenuBar"
        public static let notifyFinished = "notify.finished"
        public static let autoUpdate = "update.auto"
        public static let updateChannel = "update.channel"
        public static let updateFeedURL = "update.feedURL"
        public static let updateLastCheck = "update.lastCheck"
        public static let editorFontSize = "editor.fontSize"
        /// 编辑器代码字体族(默认 System monospace)
        public static let editorFontFamily = "editor.fontFamily"
        public static let editorWrap = "editor.wrap"
        public static let editorLargeFileLines = "editor.largeFileLines"
        /// 编辑器是否启用语言服务器(诊断/悬停/跳转/补全)
        public static let editorLSP = "editor.lsp"
        /// Agent 每次编辑文件后,自动在编辑器中打开并定位到首个改动行(默认关闭)
        public static let editorFollowAgent = "editor.followAgent"
        /// Agent 终端输出字号(工具行里的命令输出)
        public static let terminalFontSize = "terminal.fontSize"
        /// 交互终端:字体族、字号、光标形状/闪烁、回滚行数、Option 当 Meta、Shell 路径、登录 Shell、起始目录
        public static let terminalShellFontFamily = "terminal.shell.fontFamily"
        public static let terminalShellFontSize = "terminal.shell.fontSize"
        public static let terminalCursorShape = "terminal.shell.cursorShape"
        public static let terminalCursorBlink = "terminal.shell.cursorBlink"
        public static let terminalScrollback = "terminal.shell.scrollback"
        public static let terminalOptionAsMeta = "terminal.shell.optionAsMeta"
        public static let terminalShellPath = "terminal.shell.path"
        public static let terminalLoginShell = "terminal.shell.login"
        public static let terminalStartDirectory = "terminal.shell.startDirectory"
        public static let terminalOutputKB = "terminal.outputLimitKB"
        public static let terminalInheritEnv = "terminal.inheritEnvironment"
        /// Agent 终端沙箱(默认关闭)与网络档位(off/local/all)
        public static let terminalSandbox = "terminal.sandbox.enabled"
        public static let terminalSandboxNetwork = "terminal.sandbox.network"
        public static let budgetUSD = "usage.budgetUSD"
        public static let redactLogs = "privacy.redactLogs"
        /// 自动压缩窗口(token,0 = 默认):给上下文设上限,对应 CLAUDE_CODE_AUTO_COMPACT_WINDOW
        public static let autoCompactWindow = "advanced.autoCompactWindow"
        public static let pathNode = "advanced.path.node"
        public static let pathClaude = "advanced.path.claude"
        public static let pathAdapter = "advanced.path.adapter"
        public static let featureFileSystem = "feature.fileSystem"
        public static let featureTerminal = "feature.terminal"
        /// 声明 `_meta.terminal_output`:显示 Agent 自己执行的命令输出(含后台命令)
        public static let featureAgentTerminalOutput = "feature.agentTerminalOutput"
        public static let featureElicitation = "feature.elicitation"
        /// 聊天内容宽度档位(narrow/standard/wide/full)
        public static let chatWidth = "chat.width"
        /// 自定义聊天宽度(点),`chat.width == custom` 时生效
        public static let chatWidthCustom = "chat.widthCustom"
        /// MCP 工具按需加载(Claude Code 的 ENABLE_TOOL_SEARCH):auto / on / off
        public static let mcpToolSearch = "mcp.toolSearch"
        /// 设置页内容宽度档位(compact/standard/wide/full/custom)
        public static let settingsWidth = "settings.width"
        /// 自定义设置页宽度(点),`settings.width == custom` 时生效
        public static let settingsWidthCustom = "settings.widthCustom"
        /// 发送键(enter / commandEnter)
        public static let sendKey = "chat.sendKey"
        /// 运行中再发送的默认行为(steer / queue)
        public static let runningSend = "chat.runningSend"
        /// 任务完成通知是否带提示音
        public static let notifySound = "notify.sound"
        public static let proxyMode = "network.proxyMode"
        public static let proxyAddress = "network.proxyAddress"
        public static let requestTimeout = "network.timeoutSeconds"
        public static let appendPrompt = "prompt.append"
        /// 辅助任务模型(`UtilityModelChoice.raw`):会话标题生成 / 提示词优化;空 = 自动,标题另有 off
        public static let titleModel = "prompt.titleModel"
        public static let optimizeModel = "prompt.optimizeModel"
        public static let loadClaudeMemory = "prompt.loadClaudeMemory"
        /// 是否显示第三方 Agent 的扩展通知行(如 pi-tps 的「TPS …」),默认显示为淡色小字
        public static let showAgentNotify = "agent.showNotify"
        /// 等待动词风格(`WorkingVerbStyle`):classic / playful / claudeCode / poetic / geek / minimal
        public static let workingVerbStyle = "appearance.workingVerbStyle"
        /// 滚动条显示方式(`ScrollbarVisibility`):system / autoHide / always
        public static let scrollbarVisibility = "appearance.scrollbarVisibility"
        /// 工具调用详细程度(`ToolDensity`):compact / standard / detailed
        public static let toolDensity = ToolDensity.preferenceKey
        /// 聊天代码块自动换行(默认关闭,横向滚动)
        public static let chatCodeWrap = "chat.codeWrap"
        /// 提交时附带 `Co-authored-by: OhMyAgent` 署名(默认关闭)
        public static let scmCoAuthor = "scm.coAuthor"
        /// 源代码管理面板显示「AI 生成提交说明」按钮(默认开启)
        public static let scmAICommitMessage = "scm.aiCommitMessage"
        /// 同时保留的语言服务器工作区上限(1–8,默认 4)
        public static let lspMaxWorkspaces = "codeIntel.maxLSPWorkspaces"
        /// 工作树自动清理的检查间隔(小时,默认 6)与数量上限(默认 25)
        public static let worktreeCleanupHours = "worktree.cleanupIntervalHours"
        public static let worktreeMaxCount = "worktree.maxCount"
        /// 索引忽略 glob(多行文本)
        public static let indexIgnoreGlobs = IndexIgnore.preferenceKey
    }

    /// 托盘图标是否启用:菜单栏开关打开,或 Dock 图标被隐藏(此时必须有托盘才能打开窗口)。默认开启。
    public static func trayEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        let dock = defaults.object(forKey: Key.showDock) as? Bool ?? true
        let bar = defaults.object(forKey: Key.showMenuBar) as? Bool ?? true
        return bar || !dock
    }

    /// 任务完成时是否发送系统通知,默认开启。
    public static func notifiesOnFinish(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: Key.notifyFinished) as? Bool ?? true
    }

    /// 发送键,默认 Return 发送。
    public static func sendKey(_ defaults: UserDefaults = .standard) -> SendKey {
        SendKey(rawValue: defaults.string(forKey: Key.sendKey) ?? "") ?? .enter
    }

    /// 运行中再发送的默认行为,默认引导。
    public static func runningSendMode(_ defaults: UserDefaults = .standard) -> RunningSendMode {
        RunningSendMode(rawValue: defaults.string(forKey: Key.runningSend) ?? "") ?? .steer
    }

    /// 是否显示第三方 Agent 的扩展通知行(info 级别),默认开启;warning / error 级别始终显示。
    public static func showsAgentNotify(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: Key.showAgentNotify) as? Bool ?? true
    }

    /// 完成通知是否带提示音,默认开启。
    public static func notifiesWithSound(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: Key.notifySound) as? Bool ?? true
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

    /// Agent 终端沙箱配置(设置页「Agent 终端」)。
    public static func terminalSandboxConfig(_ defaults: UserDefaults = .standard) -> TerminalSandboxConfig {
        TerminalSandboxConfig(
            enabled: defaults.object(forKey: Key.terminalSandbox) as? Bool ?? false,
            network: TerminalSandboxConfig.Network(rawValue: defaults.string(forKey: Key.terminalSandboxNetwork) ?? "") ?? .local)
    }

    /// 工作树数量上限(1–200,默认 25)。
    public static func worktreeMaxCount(_ defaults: UserDefaults = .standard) -> Int {
        min(max(defaults.object(forKey: Key.worktreeMaxCount) as? Int ?? 25, 1), 200)
    }

    /// 工作树清理检查间隔(1–168 小时,默认 6)。
    public static func worktreeCleanupHours(_ defaults: UserDefaults = .standard) -> Int {
        min(max(defaults.object(forKey: Key.worktreeCleanupHours) as? Int ?? 6, 1), 168)
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

    /// 用户重命名过的会话标题(会话 ID → 标题);适配器不提供改名接口,故保存在客户端。
    public static func sessionTitleOverrides(_ defaults: UserDefaults = .standard) -> [String: String] {
        defaults.dictionary(forKey: "session.titleOverrides") as? [String: String] ?? [:]
    }

    /// 保存会话标题覆盖;`title` 为空时移除。
    /// - Parameters:
    ///   - title: 新标题
    ///   - sessionId: 会话 ID
    public static func setSessionTitle(_ title: String?, for sessionId: String, _ defaults: UserDefaults = .standard) {
        var map = sessionTitleOverrides(defaults)
        if let title, !title.isEmpty { map[sessionId] = title } else { map.removeValue(forKey: sessionId) }
        defaults.set(map, forKey: "session.titleOverrides")
    }

    /// 自动生成的会话标题(会话 ID → 标题);优先级低于用户重命名,高于适配器列表里的原始标题。
    public static func generatedSessionTitles(_ defaults: UserDefaults = .standard) -> [String: String] {
        defaults.dictionary(forKey: "session.generatedTitles") as? [String: String] ?? [:]
    }

    /// 保存自动生成的标题;`title` 为空时移除。
    /// - Parameters:
    ///   - title: 标题
    ///   - sessionId: 会话 ID
    public static func setGeneratedSessionTitle(_ title: String?, for sessionId: String, _ defaults: UserDefaults = .standard) {
        var map = generatedSessionTitles(defaults)
        if let title, !title.isEmpty { map[sessionId] = title } else { map.removeValue(forKey: sessionId) }
        defaults.set(map, forKey: "session.generatedTitles")
    }

    /// 删除全部客户端偏好(不含 Claude 设置)。
    public static func resetAll(_ defaults: UserDefaults = .standard) {
        for key in defaults.dictionaryRepresentation().keys {
            let prefixes = ["general.", "update.", "editor.", "terminal.", "usage.", "privacy.", "advanced.", "feature.", "appearance.", "shortcut.", "chat.", "notify.", "network.", "prompt."]
            if prefixes.contains(where: { key.hasPrefix($0) }) { defaults.removeObject(forKey: key) }
        }
    }
}
