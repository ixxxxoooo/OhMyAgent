// @author ixxxxoooo
// 提示词优化:把输入框里的草稿改写得更清晰、具体、可执行。
// 有模型映射时经本机网关用小模型槽位;否则单独起一个 `claude -p`(无工具、无 MCP、不落盘会话),使用本机 claude 自带的凭据。

import ACPKit
import AgentHost
import Foundation
import OMLog

/// 提示词优化器(纯逻辑 + 一次轻量模型请求)。
public enum PromptOptimizer {
    /// 允许优化的最大字符数(再长的草稿多半是粘贴的资料,改写会丢内容)
    public static let maxInputLength = 8000

    /// 优化指令(作为系统提示词)。
    public static let systemPrompt = """
    你是提示词优化助手。用户会给你一段准备发给编程 Agent 的提示词,请在不改变原意的前提下把它改写得更清晰、具体、可执行:
    - 先写清楚目标,再写范围与约束;原文有多个要求时拆成有序的要点;去掉口语赘述和重复。
    - 严格原样保留:@ 文件或目录引用、/ 斜杠命令、代码块、文件路径、标识符、URL、数字、专有名词和报错原文。
    - 不要编造原文没有的需求、文件名、技术栈或细节;信息不足时保持简短,不要凭空补充。
    - 输出语言与原文一致。
    - 只输出优化后的提示词本身,不要解释、标题、引号、前缀或代码围栏。
    """

    /// 草稿是否值得优化:非空、不超过上限、且不是单个斜杠命令(如 `/clear`)。
    /// - Parameter draft: 输入框草稿
    /// - Returns: 可以优化时为 true
    public static func isOptimizable(_ draft: String) -> Bool {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= maxInputLength else { return false }
        if text.hasPrefix("/"), !text.contains(where: \.isWhitespace) { return false }
        return true
    }

    /// 清洗模型输出:去代码围栏、整体引号与「优化后的提示词:」前缀。
    /// - Parameter raw: 模型原始输出
    /// - Returns: 可直接放回输入框的文本;没有有效内容返回 nil
    public static func clean(_ raw: String) -> String? {
        var lines = raw.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        // 只有整段被围栏包住时才去掉围栏;正文里自带的代码块必须保留
        if let first = lines.first, first.trimmingCharacters(in: .whitespaces).hasPrefix("```"),
           let last = lines.last, last.trimmingCharacters(in: .whitespaces) == "```", lines.count >= 2 {
            lines.removeFirst()
            lines.removeLast()
        }
        var text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["优化后的提示词:", "优化后的提示词\u{FF1A}", "优化后:", "优化后\u{FF1A}", "Optimized prompt:", "Optimized Prompt:"] where text.hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let quotes = CharacterSet(charactersIn: "\"“”")
        if text.count > 2, let first = text.unicodeScalars.first, let last = text.unicodeScalars.last,
           quotes.contains(first), quotes.contains(last) {
            text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text.isEmpty ? nil : text
    }

    /// 演示模式下的确定性改写(不访问模型,仅用于验证界面流程)。
    /// - Parameter draft: 输入框草稿
    /// - Returns: 带固定前缀的文本
    public static func demoRewrite(_ draft: String) -> String {
        "请完成下面的任务,并在结束时说明改动与验证结果:\n\(draft.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    // MARK: 网关通道

    /// 构造 Anthropic Messages 请求体(无工具)。
    /// - Parameters:
    ///   - model: 网关模型别名
    ///   - text: 草稿
    /// - Returns: JSON 数据
    public static func requestBody(model: String, text: String) -> Data? {
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 2000,
            "stream": false,
            "system": systemPrompt,
            "messages": [["role": "user", "content": text]],
        ]
        return try? JSONSerialization.data(withJSONObject: body)
    }

    /// 经本机模型网关优化。
    /// - Parameters:
    ///   - gateway: 网关地址
    ///   - model: 网关模型别名(通常取小模型槽位)
    ///   - text: 草稿
    ///   - timeout: 超时
    ///   - session: URLSession(测试可注入)
    /// - Returns: 清洗后的提示词;失败返回 nil
    public static func viaGateway(gateway: URL, model: String, text: String, timeout: TimeInterval = 60, session: URLSession = .shared) async -> String? {
        guard let body = requestBody(model: model, text: text) else { return nil }
        var request = URLRequest(url: gateway.appendingPathComponent("v1/messages"), timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue(ProviderLaunch.placeholderToken, forHTTPHeaderField: "x-api-key")
        let started = ContinuousClock.now
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                Log.session.warning("优化提示词失败", ["channel": "gateway", "status": "\((response as? HTTPURLResponse)?.statusCode ?? -1)"])
                return nil
            }
            let result = TitleGenerator.responseText(from: data).flatMap(clean)
            Log.session.info("优化提示词完成", ["channel": "gateway", "ms": "\(OMLogger.milliseconds(since: started))", "ok": "\(result != nil)"])
            return result
        } catch {
            Log.session.warning("优化提示词请求出错", ["channel": "gateway", "reason": error.localizedDescription])
            return nil
        }
    }

    // MARK: claude 通道

    /// `claude -p` 的启动参数:流式 JSON 收发、无工具、无 MCP、无技能、不落盘;自带 BASE_URL 的第三方网关环境下不指定模型别名。
    /// - Parameter environment: claude 运行时的环境变量
    /// - Returns: 参数列表
    static func claudeArguments(environment: [String: String]) -> [String] {
        var arguments = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--no-session-persistence",
                         "--tools", "", "--strict-mcp-config", "--disable-slash-commands",
                         // 不读 user/project/local 设置(hooks、插件、技能、权限规则),实测首轮输入约 13K → 0.6K token
                         "--setting-sources", ""]
        if (environment["ANTHROPIC_BASE_URL"] ?? "").isEmpty { arguments += ["--model", "haiku"] }
        arguments += ["--system-prompt", systemPrompt]
        return arguments
    }

    /// 优化专用的最小环境:`--setting-sources ""` 会忽略 `~/.claude/settings.json`,
    /// 所以把其中的 `env`(如第三方网关地址)并进来保持与终端一致,再关闭 CLAUDE.md 与自动记忆注入。
    /// - Parameters:
    ///   - base: claude 运行时的环境变量
    ///   - settingsEnv: `~/.claude/settings.json` 的 `env`(同名时优先,与 Claude Code 一致)
    /// - Returns: 实际传给子进程的环境
    static func minimalEnvironment(base: [String: String], settingsEnv: [String: String]) -> [String: String] {
        var env = base.merging(settingsEnv) { _, settings in settings }
        env["CLAUDE_CODE_DISABLE_CLAUDE_MDS"] = "1"
        env["CLAUDE_CODE_DISABLE_AUTO_MEMORY"] = "1"
        return env
    }

    /// 构造 stream-json 输入里的用户消息。
    /// - Parameter text: 草稿
    /// - Returns: 一行 JSON
    static func userMessage(_ text: String) -> Data? {
        let message: [String: Any] = ["type": "user", "message": ["role": "user", "content": text]]
        return try? JSONSerialization.data(withJSONObject: message)
    }

    /// 解析 stream-json 输出里的 `result` 行。
    /// - Parameter line: 一行输出
    /// - Returns: 非 `result` 行为 nil;否则给出文本与是否出错
    static func parseResult(_ line: Data) -> (text: String, isError: Bool)? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any], object["type"] as? String == "result" else { return nil }
        let isError = (object["is_error"] as? Bool ?? false) || (object["subtype"] as? String).map { $0 != "success" } ?? false
        return (object["result"] as? String ?? "", isError)
    }

    /// 起一个 `claude -p` 优化。
    /// - Parameters:
    ///   - claude: claude 可执行文件路径
    ///   - environment: 运行环境(登录 shell 解析结果)
    ///   - cwd: 工作目录
    ///   - text: 草稿
    ///   - timeout: 整体超时
    /// - Returns: 清洗后的提示词;失败返回 nil
    public static func viaClaude(claude: String, environment: [String: String], cwd: String, text: String, timeout: Duration = .seconds(90)) async -> String? {
        guard !claude.isEmpty, let payload = userMessage(text) else { return nil }
        let environment = minimalEnvironment(base: environment, settingsEnv: ModelGateway.loadSettingsEnv())
        let transport = StdioTransport(launch: ProcessLaunch(executable: claude, arguments: claudeArguments(environment: environment), environment: environment, workingDirectory: cwd))
        let events: AsyncStream<TransportEvent>
        do { events = try transport.start() } catch {
            Log.session.error("优化提示词启动 claude 失败", error: error)
            return nil
        }
        // 超时即结束进程,事件流随之结束,下面的读取自然返回
        let watchdog = Task {
            try? await Task.sleep(for: timeout)
            transport.stop()
        }
        defer {
            watchdog.cancel()
            transport.stop()
        }
        let started = ContinuousClock.now
        transport.send(payload)
        for await event in events {
            switch event {
            case .line(let data):
                StdioTransport.backlog.consumed()
                guard let result = parseResult(data) else { continue }
                let cleaned = result.isError ? nil : clean(result.text)
                Log.session.info("优化提示词完成", ["channel": "claude", "ms": "\(OMLogger.milliseconds(since: started))", "ok": "\(cleaned != nil)"])
                return cleaned
            case .stderr, .message:
                continue
            case .closed:
                Log.session.warning("优化提示词的 claude 进程提前退出", ["ms": "\(OMLogger.milliseconds(since: started))"])
                return nil
            }
        }
        return nil
    }
}
