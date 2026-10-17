// @author ixxxxoooo
// Agent 终端的辅助:环境标记、输出清洗与可选沙箱(对照 Cursor 终端文档)。
// - `OHMYAGENT_AGENT=1`:只注入给 Agent 的进程,方便在 `.zshrc` 里为 Agent 跳过 Powerlevel10k 等重型提示符主题;
// - `TerminalOutputSanitizer`:管道输出里剔除提示符/标题/私有模式等转义序列,只保留 SGR 颜色,避免内联输出错乱;
// - `TerminalSandbox`:用 `sandbox-exec`(系统已标记弃用但仍可用)限制写权限与网络;默认关闭。

import Foundation

/// Agent 进程环境标记。
public enum AgentEnvironment {
    /// 环境变量名:值为 `1` 表示命令由 Agent 触发(用户自己打开的终端不会有)。
    public static let marker = "OHMYAGENT_AGENT"

    /// 在环境里加入 Agent 标记。
    /// - Parameter environment: 环境变量表
    /// - Returns: 带标记的新环境
    public static func marked(_ environment: [String: String]) -> [String: String] {
        var result = environment
        result[marker] = "1"
        return result
    }

    /// 在 `.zshrc` 里跳过重型主题的示例(设置页「终端」展示并可复制)。
    public static let zshSnippet = """
    # Use a minimal prompt for commands triggered by OhMyAgent / agents
    if [[ -n $OHMYAGENT_AGENT ]]; then
      PS1='%~ %# '
      unsetopt zle 2>/dev/null
    else
      # Only load heavy themes (e.g. Powerlevel10k) in your own terminals
      [[ -r ~/.p10k.zsh ]] && source ~/.p10k.zsh
    fi
    """

    /// 在 `.bashrc` 里的等价示例。
    public static let bashSnippet = """
    # Use a minimal prompt for commands triggered by OhMyAgent / agents
    if [ -n "$OHMYAGENT_AGENT" ]; then
      PS1='\\w \\$ '
      unset PROMPT_COMMAND
    fi
    """
}

/// 终端输出清洗:去掉管道里不该出现的控制序列。
public enum TerminalOutputSanitizer {
    /// 清洗输出:删除 OSC(标题、`133;` 提示符标记、`1337;` 等)、DCS/APC/PM/SOS、非 SGR 的 CSI(含 `?2004h` 括号粘贴、光标移动、清屏)
    /// 与孤立的 ESC 序列;保留 SGR(颜色/粗体,以 `m` 结尾)、换行与制表符;丢弃其他 C0 控制字符(BEL、退格等)。
    /// - Parameter text: 原始输出
    /// - Returns: 清洗后的文本
    public static func clean(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        guard scalars.contains(where: { $0.value == 0x1B || ($0.value < 0x20 && $0 != "\n" && $0 != "\t" && $0 != "\r") || $0.value == 0x7F }) else { return text }
        var output = String.UnicodeScalarView()
        var index = 0
        func skipString(from start: Int) -> Int {
            // 以 BEL 或 ESC \ (ST) 结尾
            var i = start
            while i < scalars.count {
                if scalars[i].value == 0x07 { return i + 1 }
                if scalars[i].value == 0x1B, i + 1 < scalars.count, scalars[i + 1] == "\\" { return i + 2 }
                i += 1
            }
            return i
        }
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar.value == 0x1B {
                guard index + 1 < scalars.count else { break }
                let next = scalars[index + 1]
                switch next {
                case "[":
                    // CSI:参数 0x30–0x3F,中间 0x20–0x2F,终结 0x40–0x7E
                    var i = index + 2
                    while i < scalars.count, (0x30...0x3F).contains(scalars[i].value) || (0x20...0x2F).contains(scalars[i].value) { i += 1 }
                    if i < scalars.count {
                        if scalars[i] == "m" { output.append(contentsOf: scalars[index...i]) }
                        index = i + 1
                    } else {
                        index = i
                    }
                case "]", "P", "X", "^", "_":
                    index = skipString(from: index + 2)
                default:
                    // 两字符序列(如 ESC = / ESC > / ESC 7)
                    index += 2
                }
                continue
            }
            if scalar.value < 0x20, scalar != "\n", scalar != "\t", scalar != "\r" { index += 1; continue }
            if scalar.value == 0x7F { index += 1; continue }
            output.append(scalar)
            index += 1
        }
        return String(output)
    }
}

/// 沙箱配置。
public struct TerminalSandboxConfig: Sendable, Equatable, Codable {
    /// 网络档位。
    public enum Network: String, Sendable, Codable, CaseIterable {
        /// 完全禁止
        case off
        /// 仅本机回环
        case local
        /// 不限制
        case all
    }

    public var enabled: Bool
    public var network: Network
    /// 额外可写目录(绝对路径)
    public var writablePaths: [String]

    public init(enabled: Bool = false, network: Network = .local, writablePaths: [String] = []) {
        self.enabled = enabled
        self.network = network
        self.writablePaths = writablePaths
    }
}

/// `sandbox-exec` 封装。
public enum TerminalSandbox {
    public static let executable = "/usr/bin/sandbox-exec"

    /// 系统里是否存在 `sandbox-exec`。
    public static var isAvailable: Bool { FileManager.default.isExecutableFile(atPath: executable) }

    /// 读取工作区的 `.oma/sandbox.json`(`network`、`additionalWritablePaths`)覆盖基础配置。
    /// - Parameters:
    ///   - base: 设置页里的基础配置
    ///   - workspace: 工作区根目录
    /// - Returns: 合并后的配置;文件不存在或损坏时返回基础配置
    public static func resolve(base: TerminalSandboxConfig, workspace: String) -> TerminalSandboxConfig {
        let url = URL(fileURLWithPath: workspace).appendingPathComponent(".oma/sandbox.json")
        guard let data = try? Data(contentsOf: url), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return base }
        var config = base
        if let raw = object["network"] as? String, let network = TerminalSandboxConfig.Network(rawValue: raw) { config.network = network }
        if let paths = object["additionalWritablePaths"] as? [String] {
            let expanded = paths.map { ($0 as NSString).expandingTildeInPath }.map { $0.hasPrefix("/") ? $0 : (workspace as NSString).appendingPathComponent($0) }
            config.writablePaths += expanded
        }
        return config
    }

    /// 生成 SBPL 配置:默认放行,但禁止写文件(白名单除外),并按档位限制网络。
    /// - Parameters:
    ///   - workspace: 工作区根目录(可写)
    ///   - config: 沙箱配置
    ///   - home: 用户主目录(缓存目录可写)
    /// - Returns: `sandbox-exec -p` 使用的配置文本
    public static func profile(workspace: String, config: TerminalSandboxConfig, home: String = NSHomeDirectory()) -> String {
        // SBPL 要求真实路径;Foundation 的 resolvingSymlinksInPath 会把 /private/var 还原成 /var,故用 realpath
        func real(_ path: String) -> String {
            guard let resolved = realpath(path, nil) else { return path }
            defer { free(resolved) }
            return String(cString: resolved)
        }
        func quoted(_ path: String) -> String {
            "\"" + real(path).replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        var writable = [workspace, NSTemporaryDirectory(), "/tmp", "/private/tmp", "/private/var/folders",
                        home + "/Library/Caches", home + "/.cache", home + "/.npm", home + "/.cargo", home + "/.gradle", home + "/.swiftpm"]
        writable += config.writablePaths
        var lines = ["(version 1)", "(allow default)", "(deny file-write*)", "(allow file-write*"]
        lines += writable.map { "  (subpath \(quoted($0)))" }
        lines += ["  (literal \"/dev/null\")", "  (literal \"/dev/tty\")", "  (literal \"/dev/dtracehelper\")", "  (subpath \"/dev/fd\")", "  (regex #\"^/dev/ttys[0-9]+$\"))"]
        switch config.network {
        case .all: break
        case .off: lines.append("(deny network*)")
        case .local:
            lines += ["(deny network*)",
                      "(allow network-outbound (remote ip \"localhost:*\"))",
                      "(allow network-inbound (local ip \"localhost:*\"))",
                      "(allow network-bind (local ip \"localhost:*\"))"]
        }
        return lines.joined(separator: "\n")
    }

    /// 输出是否像被沙箱拦截(写权限被拒、网络不可用)。
    /// - Parameters:
    ///   - output: 命令输出
    ///   - exitCode: 退出码
    public static func looksBlocked(output: String, exitCode: Int?) -> Bool {
        guard let exitCode, exitCode != 0 else { return false }
        let lower = output.lowercased()
        return ["operation not permitted", "read-only file system", "sandbox", "deny file-write"].contains { lower.contains($0) }
    }
}
