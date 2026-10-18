// @author ixxxxoooo
// 浏览器(Bridge 工具 `browser_*`):ChatKit 只定义命令、入参解析、URL 规整与结果格式化,
// 真正的网页由应用层的 WKWebView 标签页实现并通过 `BrowserProvider` 注入(与 `CodeSearchProvider` 同一模式)。

import ACPKit
import AgentHost
import Foundation
import Synchronization

/// 浏览器命令。
public enum BrowserCommand: Sendable, Equatable {
    case navigate(url: URL)
    /// 页面可访问性快照(带可点击元素的 ref)
    case snapshot
    /// 点击(`button`:左键/右键;`double`:双击)
    case click(ref: String, button: BrowserMouseButton = .left, double: Bool = false)
    /// 悬停(触发 hover 样式、下拉菜单、tooltip)
    case hover(ref: String)
    /// 前进 / 后退 / 刷新
    case history(BrowserHistoryAction)
    case type(ref: String, text: String, submit: Bool)
    case scroll(BrowserScroll)
    case screenshot
    case console
    /// 网络请求记录;`request` 为序号时返回该请求的详情(请求/响应载荷预览)
    case network(request: Int? = nil)
    case tabs
}

/// 鼠标按键。
public enum BrowserMouseButton: String, Sendable, Equatable {
    case left, right
}

/// 历史导航动作。
public enum BrowserHistoryAction: String, Sendable, Equatable {
    case back, forward, reload
}

/// 滚动目标。
public enum BrowserScroll: Sendable, Equatable {
    case up, down, top, bottom
    /// 滚动到元素可见
    case element(ref: String)
}

/// 浏览器命令的结果。
public struct BrowserResult: Sendable, Equatable {
    public var text: String
    public var imagePNG: Data?
    public var isError: Bool

    public init(_ text: String, imagePNG: Data? = nil, isError: Bool = false) {
        self.text = text
        self.imagePNG = imagePNG
        self.isError = isError
    }
}

/// 入参解析与 URL 规整。
public enum BrowserArguments {
    /// 规整地址:缺少协议时补 `https://`(本机地址补 `http://`);只允许 http/https,拒绝 `javascript:`、`file:`、`data:` 等。
    /// - Parameter text: 用户或模型给出的地址
    /// - Returns: 可导航的 URL;不合法为 nil
    public static func normalize(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isNewline) else { return nil }
        var candidate = trimmed
        if let range = candidate.range(of: "://") {
            // 显式协议:只放行 http/https
            let scheme = candidate[candidate.startIndex..<range.lowerBound].lowercased()
            guard scheme == "http" || scheme == "https" else { return nil }
        } else {
            if let colon = candidate.firstIndex(of: ":") {
                // 没有 `//` 的协议(`javascript:`、`data:`、`mailto:`)一律拒绝;只有「主机名:端口」写法放行
                let head = candidate[candidate.startIndex..<colon]
                let hostLike = head == "localhost" || head.contains(".") || head.hasPrefix("[")
                if !(hostLike && isPortOnly(candidate, colon: colon)), !head.contains("/") { return nil }
            }
            let host = candidate.split(whereSeparator: { $0 == "/" || $0 == ":" || $0 == "?" || $0 == "#" }).first.map(String.init) ?? ""
            let local = host == "localhost" || host == "127.0.0.1" || host == "[::1]" || host.hasSuffix(".local")
            candidate = (local ? "http://" : "https://") + candidate
        }
        guard let url = URL(string: candidate), let host = url.host, !host.isEmpty, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }

    /// `host:8080` 这类「冒号后全是端口」的写法不是协议。
    private static func isPortOnly(_ text: String, colon: String.Index) -> Bool {
        let rest = text[text.index(after: colon)...].prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        return !rest.isEmpty && rest.allSatisfy(\.isNumber)
    }

    /// 从 MCP 入参解析命令。
    /// - Parameters:
    ///   - tool: 工具
    ///   - arguments: 入参
    /// - Returns: 命令;失败时返回面向模型的错误说明
    public static func parse(_ tool: BridgeTool, _ arguments: JSONValue) -> Result<BrowserCommand, BrowserParseError> {
        func ref() -> String? {
            guard let value = arguments["ref"]?.stringValue?.trimmingCharacters(in: .whitespaces), !value.isEmpty,
                  value.count <= 16, value.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
            return value
        }
        switch tool {
        case .browserNavigate:
            guard let text = arguments["url"]?.stringValue else { return .failure(.init("Missing url argument")) }
            guard let url = normalize(text) else { return .failure(.init("Invalid url: only http/https addresses are supported")) }
            return .success(.navigate(url: url))
        case .browserSnapshot: return .success(.snapshot)
        case .browserClick:
            guard let ref = ref() else { return .failure(.init("Missing or invalid ref (call browser_snapshot first to get one)")) }
            let raw = arguments["button"]?.stringValue?.lowercased() ?? "left"
            guard let button = BrowserMouseButton(rawValue: raw) else { return .failure(.init("button must be left or right")) }
            return .success(.click(ref: ref, button: button, double: arguments["double"]?.boolValue ?? false))
        case .browserHover:
            guard let ref = ref() else { return .failure(.init("Missing or invalid ref (call browser_snapshot first to get one)")) }
            return .success(.hover(ref: ref))
        case .browserBack: return .success(.history(.back))
        case .browserForward: return .success(.history(.forward))
        case .browserReload: return .success(.history(.reload))
        case .browserType:
            guard let ref = ref() else { return .failure(.init("Missing or invalid ref (call browser_snapshot first to get one)")) }
            guard let text = arguments["text"]?.stringValue else { return .failure(.init("Missing text argument")) }
            guard text.count <= 10_000 else { return .failure(.init("text is too long (limit 10000 characters)")) }
            return .success(.type(ref: ref, text: text, submit: arguments["submit"]?.boolValue ?? false))
        case .browserScroll:
            if let ref = ref() { return .success(.scroll(.element(ref: ref))) }
            switch arguments["direction"]?.stringValue?.lowercased() ?? "down" {
            case "up": return .success(.scroll(.up))
            case "down": return .success(.scroll(.down))
            case "top": return .success(.scroll(.top))
            case "bottom": return .success(.scroll(.bottom))
            default: return .failure(.init("direction must be one of up/down/top/bottom"))
            }
        case .browserScreenshot: return .success(.screenshot)
        case .browserConsole: return .success(.console)
        case .browserNetwork:
            guard let raw = arguments["request"] else { return .success(.network()) }
            guard let index = raw.intValue, index >= 1 else { return .failure(.init("request must be a positive request number from the browser_network list")) }
            return .success(.network(request: index))
        case .browserTabs: return .success(.tabs)
        default: return .failure(.init("Not a browser tool"))
        }
    }
}

/// 入参解析错误(面向模型的说明)。
public struct BrowserParseError: Error, Equatable, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
}

/// 浏览器实现的登记处(应用启动时注入)。
public final class BrowserProvider: Sendable {
    public static let shared = BrowserProvider()
    public typealias Handler = @Sendable (_ workspace: String, _ command: BrowserCommand) async -> BrowserResult
    private let handler = Mutex<Handler?>(nil)
    /// 查询工作区当前浏览器页面的地址(审批用:点击、输入等没有 url 参数的动作按当前页面的来源判断是否放行)
    public typealias CurrentURL = @Sendable (_ workspace: String) -> String?
    private let currentURLHandler = Mutex<CurrentURL?>(nil)

    private init() {}

    /// 注入「当前页面地址」查询。
    /// - Parameter handler: 返回该工作区当前浏览器标签的 URL;没有页面时为 nil
    public func installCurrentURL(_ handler: @escaping CurrentURL) {
        currentURLHandler.withLock { $0 = handler }
    }

    /// 工作区当前浏览器页面的地址。
    /// - Parameter workspace: 工作区路径
    public func currentURL(workspace: String) -> String? {
        currentURLHandler.withLock { $0 }?(workspace)
    }

    /// 注入实现。
    /// - Parameter handler: 在该工作区的浏览器标签页上执行命令
    public func install(_ handler: @escaping Handler) {
        self.handler.withLock { $0 = handler }
    }

    /// 执行命令;未注入实现时返回 nil。
    public func run(workspace: String, command: BrowserCommand) async -> BrowserResult? {
        guard let handler = handler.withLock({ $0 }) else { return nil }
        return await handler(workspace, command)
    }
}

extension SessionBridge {
    /// 浏览器类工具。
    func callBrowser(_ tool: BridgeTool, arguments: JSONValue) async -> BridgeResult {
        switch BrowserArguments.parse(tool, arguments) {
        case .failure(let error): return BridgeResult(error.message, isError: true)
        case .success(let command):
            guard let workspace = await MainActor.run(body: { model?.workspace.path }) else { return BridgeResult("The session is closed", isError: true) }
            guard let result = await BrowserProvider.shared.run(workspace: workspace, command: command) else {
                return BridgeResult("The built-in browser is not enabled in this client", isError: true)
            }
            return BridgeResult(result.text, isError: result.isError, imagePNG: result.imagePNG)
        }
    }
}
