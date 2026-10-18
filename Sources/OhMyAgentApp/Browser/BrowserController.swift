// @author ixxxxoooo
// 内置浏览器:每个浏览器标签一个 `WKWebView`(项目里唯一使用 WebView 的地方),同一工作区共用一份持久化的网站数据
// (Cookie、登录状态),Agent 经 Bridge 的 `browser_*` 工具与用户在同一个标签页上协作。
// 这里只做「执行命令」:导航、快照、点击、输入、滚动、截图、读取控制台与网络记录。

import AppKit
import ChatKit
import CryptoKit
import Foundation
import Observation
import OMLog
import WebKit
import WorkbenchKit

/// 控制台一行。
struct BrowserConsoleLine: Sendable, Equatable {
    var level: String
    var text: String
}

/// 网络请求一行。
struct BrowserNetworkLine: Sendable, Equatable {
    var method: String
    var url: String
    var status: Int
    var milliseconds: Int
    var error: String?
}

/// 一个浏览器标签:拥有 `WKWebView`,记录控制台与网络,并把页面状态暴露给界面。
@MainActor
@Observable
final class BrowserTabModel: NSObject {
    let id: String
    let workspace: String
    @ObservationIgnored let webView: WKWebView
    private(set) var title = ""
    private(set) var urlString = ""
    private(set) var isLoading = false
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    @ObservationIgnored private(set) var console: [BrowserConsoleLine] = []
    @ObservationIgnored private(set) var network: [BrowserNetworkLine] = []
    @ObservationIgnored private var waiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var observers: [NSKeyValueObservation] = []
    @ObservationIgnored var onTitleChange: ((String) -> Void)?
    private static let logLimit = 300

    /// - Parameters:
    ///   - id: 标签 id
    ///   - workspace: 所属工作区
    ///   - dataStore: 网站数据存储(同一工作区共用)
    init(id: String, workspace: String, dataStore: WKWebsiteDataStore) {
        self.id = id
        self.workspace = workspace
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        let controller = WKUserContentController()
        configuration.userContentController = controller
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1280, height: 800), configuration: configuration)
        super.init()
        controller.addUserScript(WKUserScript(source: BrowserScripts.hook, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        controller.add(WeakScriptHandler(self), name: "oma")
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        observers = [
            webView.observe(\.title, options: [.new]) { [weak self] view, _ in Task { @MainActor in self?.titleChanged(view.title ?? "") } },
            webView.observe(\.url, options: [.new]) { [weak self] view, _ in Task { @MainActor in self?.urlString = view.url?.absoluteString ?? "" } },
            webView.observe(\.isLoading, options: [.new]) { [weak self] view, _ in Task { @MainActor in self?.isLoading = view.isLoading } },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] view, _ in Task { @MainActor in self?.canGoBack = view.canGoBack } },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] view, _ in Task { @MainActor in self?.canGoForward = view.canGoForward } },
        ]
    }

    private func titleChanged(_ value: String) {
        title = value
        if !value.isEmpty { onTitleChange?(value) }
    }

    // MARK: 导航

    /// 导航并等待加载结束(最多 20 秒)。
    /// - Parameter url: 目标地址
    func load(_ url: URL) async {
        console.removeAll()
        network.removeAll()
        webView.load(URLRequest(url: url))
        await waitForLoad(timeout: 20)
    }

    /// 前进 / 后退 / 刷新,并等待加载结束。
    /// - Parameter action: 历史动作
    /// - Returns: 面向模型的结果说明(无可前进/后退的记录时为错误)
    func go(_ action: BrowserHistoryAction) async -> BrowserResult {
        switch action {
        case .back:
            guard webView.canGoBack else { return BrowserResult("There is no previous page in this tab's history.", isError: true) }
            webView.goBack()
        case .forward:
            guard webView.canGoForward else { return BrowserResult("There is no next page in this tab's history.", isError: true) }
            webView.goForward()
        case .reload:
            webView.reload()
        }
        try? await Task.sleep(for: .milliseconds(150))
        await waitForLoad(timeout: 20)
        return BrowserResult("\(action == .reload ? "Reloaded" : (action == .back ? "Went back to" : "Went forward to")) \(urlString.isEmpty ? "about:blank" : urlString) — title: \(title.isEmpty ? "(none)" : title)")
    }

    /// 等待当前加载结束;没有加载时立即返回。
    /// - Parameter timeout: 超时秒数
    func waitForLoad(timeout: TimeInterval) async {
        guard webView.isLoading else { return }
        let timer = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            self?.resumeWaiters()
        }
        await withCheckedContinuation { continuation in waiters.append(continuation) }
        timer.cancel()
    }

    private func resumeWaiters() {
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }

    /// 在页面里执行脚本片段(函数体,可 `return`)。
    /// - Parameters:
    ///   - body: 脚本
    ///   - arguments: 以变量形式传入的参数
    /// - Returns: 脚本返回值
    func evaluate(_ body: String, arguments: [String: Any] = [:]) async throws -> Any? {
        try await webView.callAsyncJavaScript(body, arguments: arguments, in: nil, contentWorld: .page)
    }

    /// 截取当前视口(PNG,宽度压到 1000 点以内)。
    func screenshot() async -> Data? {
        let configuration = WKSnapshotConfiguration()
        configuration.snapshotWidth = 1000
        guard let image = try? await webView.takeSnapshot(configuration: configuration),
              let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    fileprivate func receive(_ body: [String: Any]) {
        switch body["k"] as? String {
        case "console":
            console.append(BrowserConsoleLine(level: body["level"] as? String ?? "log", text: String((body["text"] as? String ?? "").prefix(2000))))
            if console.count > Self.logLimit { console.removeFirst(console.count - Self.logLimit) }
        case "net":
            network.append(BrowserNetworkLine(method: body["method"] as? String ?? "GET", url: String((body["url"] as? String ?? "").prefix(300)),
                                              status: body["status"] as? Int ?? 0, milliseconds: body["ms"] as? Int ?? 0, error: body["error"] as? String))
            if network.count > Self.logLimit { network.removeFirst(network.count - Self.logLimit) }
        default: break
        }
    }
}

extension BrowserTabModel: WKNavigationDelegate, WKUIDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        network.append(BrowserNetworkLine(method: "GET", url: String((webView.url?.absoluteString ?? "").prefix(300)), status: 200, milliseconds: 0, error: nil))
        resumeWaiters()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        console.append(BrowserConsoleLine(level: "error", text: "Navigation failed: \(error.localizedDescription)"))
        resumeWaiters()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        console.append(BrowserConsoleLine(level: "error", text: "Navigation failed: \(error.localizedDescription)"))
        resumeWaiters()
    }

    /// 只允许 http/https 与 about:blank 的导航;其他协议(file、javascript、自定义)一律拒绝。
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .cancel }
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "http" || scheme == "https" || url.absoluteString == "about:blank" { return .allow }
        Log.app.warning("浏览器拦截了非 http(s) 导航", ["scheme": scheme])
        return .cancel
    }

    /// `target=_blank` 与 `window.open` 在当前标签里打开,避免产生无人管理的窗口。
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { webView.load(URLRequest(url: url)) }
        return nil
    }
}

/// 避免 `WKUserContentController` 强引用标签模型造成循环引用。
private final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    private weak var target: BrowserTabModel?

    init(_ target: BrowserTabModel) { self.target = target }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        Task { @MainActor [weak target] in target?.receive(body) }
    }
}

/// 浏览器标签的登记处与命令执行器。
@MainActor
final class BrowserController {
    static let shared = BrowserController()
    /// 同时保留的浏览器标签上限(超出时淘汰最久未用的、且不在编辑区里的)
    static let tabLimit = 8
    private(set) var tabs: [String: BrowserTabModel] = [:]
    private var order: [String] = []
    private var active: [String: String] = [:]
    /// 非持久化数据存储(演示模式与测试用);nil 时按工作区使用持久化存储
    var ephemeral = false

    // MARK: 标签

    /// 工作区稳定的网站数据存储:由工作区路径哈希得到固定标识。
    /// - Parameter workspace: 工作区路径
    func dataStore(for workspace: String) -> WKWebsiteDataStore {
        if ephemeral { return .nonPersistent() }
        let digest = SHA256.hash(data: Data(workspace.utf8))
        let bytes = Array(digest.prefix(16))
        let uuid = bytes.withUnsafeBytes { raw -> UUID in
            raw.count == 16 ? UUID(uuid: raw.loadUnaligned(as: uuid_t.self)) : UUID()
        }
        return WKWebsiteDataStore(forIdentifier: uuid)
    }

    /// 新建一个标签。
    /// - Parameters:
    ///   - workspace: 工作区
    ///   - makeActive: 是否设为该工作区的当前标签
    @discardableResult
    func create(workspace: String, makeActive: Bool = true) -> BrowserTabModel {
        let id = String(UUID().uuidString.prefix(8)).lowercased()
        let model = BrowserTabModel(id: id, workspace: workspace, dataStore: dataStore(for: workspace))
        model.onTitleChange = { title in AppEnvironment.shared.workbench.setBrowserTitle(id: id, title: title) }
        tabs[id] = model
        order.append(id)
        if makeActive { active[workspace] = id }
        evictIfNeeded()
        return model
    }

    /// 按 id 取标签;重启后恢复出来的空标签在这里按需重建。
    /// - Parameters:
    ///   - id: 标签 id
    ///   - workspace: 工作区(重建时使用)
    func tab(id: String, workspace: String) -> BrowserTabModel {
        if let existing = tabs[id] { return existing }
        let model = BrowserTabModel(id: id, workspace: workspace, dataStore: dataStore(for: workspace))
        model.onTitleChange = { title in AppEnvironment.shared.workbench.setBrowserTitle(id: id, title: title) }
        tabs[id] = model
        order.append(id)
        return model
    }

    /// 工作区当前的浏览器标签;没有(或已被关闭)时新建并在编辑区打开。
    /// - Parameters:
    ///   - workspace: 工作区
    ///   - activate: 新建时是否切到该标签
    func current(workspace: String, activate: Bool) -> BrowserTabModel {
        let workbench = AppEnvironment.shared.workbench
        if let id = active[workspace], let model = tabs[id], workbench.isBrowserOpen(id: id) { return model }
        let model = create(workspace: workspace)
        workbench.openBrowser(id: model.id, title: String(localized: "浏览器"), activate: activate)
        return model
    }

    private func evictIfNeeded() {
        let workbench = AppEnvironment.shared.workbench
        while tabs.count > Self.tabLimit, let victim = order.first(where: { !workbench.isBrowserOpen(id: $0) }) {
            tabs[victim] = nil
            order.removeAll { $0 == victim }
            active = active.filter { $0.value != victim }
        }
    }

    // MARK: 命令

    /// 执行一条浏览器命令。
    /// - Parameters:
    ///   - command: 命令
    ///   - workspace: 工作区
    ///   - activate: 导航时是否把标签切到前台(Agent 调用时 false,不抢焦点)
    func run(_ command: BrowserCommand, workspace: String, activate: Bool = false) async -> BrowserResult {
        let started = ContinuousClock.now
        let result = await execute(command, workspace: workspace, activate: activate)
        Log.app.info("浏览器命令", ["command": Self.name(of: command), "isError": "\(result.isError)", "ms": "\(OMLogger.milliseconds(since: started))"])
        return result
    }

    private static func name(of command: BrowserCommand) -> String {
        switch command {
        case .navigate(let url): return "navigate(\(url.host ?? ""))"
        case .snapshot: return "snapshot"
        case .click(_, let button, let double): return double ? "double-click" : (button == .right ? "right-click" : "click")
        case .hover: return "hover"
        case .history(let action): return action.rawValue
        case .type: return "type"
        case .scroll: return "scroll"
        case .screenshot: return "screenshot"
        case .console: return "console"
        case .network: return "network"
        case .tabs: return "tabs"
        }
    }

    private func execute(_ command: BrowserCommand, workspace: String, activate: Bool) async -> BrowserResult {
        if case .tabs = command { return BrowserResult(describeTabs(workspace: workspace)) }
        if case .navigate(let url) = command {
            let model = current(workspace: workspace, activate: activate)
            await model.load(url)
            return BrowserResult("Opened \(model.urlString.isEmpty ? url.absoluteString : model.urlString) — title: \(model.title.isEmpty ? "(none)" : model.title)\nTake a browser_snapshot to see the page.")
        }
        guard let id = active[workspace], let model = tabs[id], AppEnvironment.shared.workbench.isBrowserOpen(id: id), !model.urlString.isEmpty else {
            return BrowserResult("No page is open yet; call browser_navigate first.", isError: true)
        }
        do {
            switch command {
            case .snapshot:
                return BrowserResult(String(describing: try await model.evaluate(BrowserScripts.snapshot) ?? ""))
            case .click(let ref, let button, let double):
                let text = try await model.evaluate(BrowserScripts.click, arguments: ["ref": ref, "button": button.rawValue, "double": double])
                try? await Task.sleep(for: .milliseconds(400))
                await model.waitForLoad(timeout: 8)
                return BrowserResult("\(text ?? "Clicked"). Now at \(model.urlString) — \(model.title)")
            case .hover(let ref):
                return BrowserResult(String(describing: try await model.evaluate(BrowserScripts.hover, arguments: ["ref": ref]) ?? "Hovered"))
            case .history(let action):
                return await model.go(action)
            case .type(let ref, let text, let submit):
                let result = try await model.evaluate(BrowserScripts.type, arguments: ["ref": ref, "text": text, "submit": submit])
                if submit {
                    try? await Task.sleep(for: .milliseconds(400))
                    await model.waitForLoad(timeout: 8)
                }
                return BrowserResult("\(result ?? "Typed"). Now at \(model.urlString)")
            case .scroll(let target):
                var ref = ""
                var direction = "down"
                switch target {
                case .element(let value): ref = value
                case .up: direction = "up"
                case .down: direction = "down"
                case .top: direction = "top"
                case .bottom: direction = "bottom"
                }
                return BrowserResult(String(describing: try await model.evaluate(BrowserScripts.scroll, arguments: ["ref": ref, "direction": direction]) ?? ""))
            case .screenshot:
                guard let png = await model.screenshot() else { return BrowserResult("Screenshot failed", isError: true) }
                return BrowserResult("Screenshot of \(model.urlString)", imagePNG: png)
            case .console:
                let lines = model.console.suffix(100)
                return BrowserResult(lines.isEmpty ? "No console messages." : lines.map { "[\($0.level)] \($0.text)" }.joined(separator: "\n"))
            case .network:
                let lines = model.network.suffix(100)
                return BrowserResult(lines.isEmpty ? "No network requests recorded." : lines.map { line in
                    "\(line.method) \(line.url) → \(line.error ?? String(line.status)) (\(line.milliseconds) ms)"
                }.joined(separator: "\n"))
            case .navigate, .tabs:
                return BrowserResult("", isError: true)
            }
        } catch {
            Log.app.warning("浏览器命令失败", ["error": error.localizedDescription])
            return BrowserResult(Self.friendly(error), isError: true)
        }
    }

    /// 把 WebKit 的脚本错误整理成给模型看的简短说明。
    private static func friendly(_ error: Error) -> String {
        let nsError = error as NSError
        if let message = nsError.userInfo["WKJavaScriptExceptionMessage"] as? String { return message }
        return error.localizedDescription
    }

    /// 工作区当前浏览器标签的地址;没有已打开且有页面的标签时为 nil。
    /// - Parameter workspace: 工作区路径
    func currentURL(workspace: String) -> String? {
        guard let id = active[workspace], let model = tabs[id], AppEnvironment.shared.workbench.isBrowserOpen(id: id), !model.urlString.isEmpty else { return nil }
        return model.urlString
    }

    private func describeTabs(workspace: String) -> String {
        let workbench = AppEnvironment.shared.workbench
        let list = order.compactMap { tabs[$0] }.filter { $0.workspace == workspace && workbench.isBrowserOpen(id: $0.id) }
        guard !list.isEmpty else { return "No browser tabs are open." }
        return list.map { "\($0.id)\($0.id == active[workspace] ? " (current)" : ""): \($0.title.isEmpty ? "(untitled)" : $0.title) — \($0.urlString.isEmpty ? "about:blank" : $0.urlString)" }.joined(separator: "\n")
    }

    /// 清除某工作区的全部网站数据(Cookie、缓存、本地存储),并释放它的标签。
    /// - Parameter workspace: 工作区路径
    func clearData(workspace: String) async {
        let store = dataStore(for: workspace)
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        await store.removeData(ofTypes: types, modifiedSince: .distantPast)
        for model in tabs.values where model.workspace == workspace { model.webView.reload() }
        Log.app.info("已清除浏览器数据")
    }
}
