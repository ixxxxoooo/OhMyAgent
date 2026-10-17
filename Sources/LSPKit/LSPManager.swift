// @author ixxxxoooo
// LSP 管理器:按「服务器种类 + 工作区根」复用客户端,懒启动、失败退避、空闲回收。

import ACPKit
import Foundation
import OMLog

/// 打开文档后的句柄,编辑器用它发送变更与查询。
public struct LSPDocumentHandle: Sendable {
    public let client: LSPClient
    public let kind: LSPServerKind
    public let key: String
    public let path: String
    public let uri: String
    public let languageID: String
}

/// 打开文档的结果。
public enum LSPOpenResult: Sendable {
    case ready(LSPDocumentHandle)
    /// 该类文件没有对应的语言服务器
    case unsupported
    /// 服务器未安装
    case unavailable(kind: LSPServerKind)
    /// 启动或握手失败
    case failed(kind: LSPServerKind, message: String)
}

/// 管理所有语言服务器客户端。
public actor LSPManager {
    /// 传输工厂:根据种类与工作区根创建传输;返回 nil 表示服务器不可用。
    public typealias TransportFactory = @Sendable (_ kind: LSPServerKind, _ projectRoot: String, _ workspaceRoot: String) -> (any ACPTransport)?

    public static let shared = LSPManager()

    private let factory: TransportFactory
    private let idleTimeout: Duration
    private let failureBackoff: TimeInterval
    private var clients: [String: LSPClient] = [:]
    private var pendingStarts: [String: Task<Result<LSPClient, any Error>, Never>] = [:]
    private var failedUntil: [String: Date] = [:]
    private var idleTasks: [String: Task<Void, Never>] = [:]
    /// 同时保留的服务器上限(0 表示不限制);超出时回收最久未用且无打开文档的服务器
    private var maxClients = 0
    private var lastUsed: [String: Date] = [:]

    /// - Parameters:
    ///   - factory: 传输工厂,默认按 `LSPServerLocator` 启动真实子进程
    ///   - idleTimeout: 无打开文档后回收服务器的等待时间
    ///   - failureBackoff: 启动失败后的退避秒数
    public init(
        factory: @escaping TransportFactory = LSPManager.defaultFactory,
        idleTimeout: Duration = .seconds(180),
        failureBackoff: TimeInterval = 30
    ) {
        self.factory = factory
        self.idleTimeout = idleTimeout
        self.failureBackoff = failureBackoff
    }

    /// 默认工厂:定位可执行文件并创建 stdio 传输。
    public static let defaultFactory: TransportFactory = { kind, projectRoot, workspaceRoot in
        guard let launch = LSPServerLocator.locate(kind, projectRoot: projectRoot, workspaceRoot: workspaceRoot) else { return nil }
        return LSPStdioTransport(launch: launch)
    }

    /// 设置同时保留的服务器上限并立即生效。
    /// - Parameter limit: 1 以上为上限;0 或负数表示不限制
    public func setMaxClients(_ limit: Int) async {
        maxClients = max(limit, 0)
        await evictIfNeeded(keeping: nil)
    }

    /// 打开文档:必要时启动服务器,并发送 didOpen。
    /// - Parameters:
    ///   - path: 文件绝对路径
    ///   - projectRoot: 所属项目根目录
    ///   - text: 当前文本
    public func open(path: String, projectRoot: String, text: String) async -> LSPOpenResult {
        guard let kind = LSPServerKind.kind(forPath: path), let languageID = LSPServerKind.languageID(forPath: path) else {
            return .unsupported
        }
        let workspace = LSPServerLocator.workspaceRoot(for: path, kind: kind, projectRoot: projectRoot)
        let key = "\(kind.rawValue)|\(workspace)"
        idleTasks[key]?.cancel()
        idleTasks[key] = nil
        if let until = failedUntil[key], until > Date() {
            return .failed(kind: kind, message: String(localized: "语言服务器最近启动失败,稍后重试"))
        }
        let client: LSPClient
        switch await ensureClient(key: key, kind: kind, projectRoot: projectRoot, workspace: workspace) {
        case .success(let value): client = value
        case .failure(let error):
            if error is MissingServer { return .unavailable(kind: kind) }
            failedUntil[key] = Date().addingTimeInterval(failureBackoff)
            return .failed(kind: kind, message: error.localizedDescription)
        }
        lastUsed[key] = Date()
        await evictIfNeeded(keeping: key)
        let uri = LSPURI.make(path: path)
        await client.didOpen(uri: uri, languageID: languageID, text: text)
        return .ready(LSPDocumentHandle(client: client, kind: kind, key: key, path: path, uri: uri, languageID: languageID))
    }

    /// 关闭文档;无文档时安排空闲回收。
    public func close(_ handle: LSPDocumentHandle) async {
        await handle.client.didClose(uri: handle.uri)
        guard await handle.client.openDocumentCount == 0 else { return }
        let key = handle.key
        idleTasks[key]?.cancel()
        let timeout = idleTimeout
        idleTasks[key] = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            await self?.recycleIfIdle(key: key)
        }
    }

    /// 当前运行中的服务器数量。
    public var runningCount: Int { clients.count }

    /// 关闭所有服务器(应用退出时调用)。
    public func shutdownAll() async {
        for (_, task) in idleTasks { task.cancel() }
        idleTasks.removeAll()
        let all = Array(clients.values)
        clients.removeAll()
        for client in all { await client.shutdown() }
    }

    // MARK: - 内部

    private struct MissingServer: Error {}

    /// 取得或启动客户端;并发请求共享同一次启动。
    private func ensureClient(key: String, kind: LSPServerKind, projectRoot: String, workspace: String) async -> Result<LSPClient, any Error> {
        if let existing = clients[key] {
            if await existing.state == .ready { return .success(existing) }
            clients[key] = nil
        }
        if let task = pendingStarts[key] { return await task.value }
        let factory = self.factory
        let task = Task<Result<LSPClient, any Error>, Never> {
            guard let transport = factory(kind, projectRoot, workspace) else { return .failure(MissingServer()) }
            let client = LSPClient(transport: transport, rootPath: workspace, label: kind.rawValue)
            do {
                try await client.start()
                return .success(client)
            } catch {
                return .failure(error)
            }
        }
        pendingStarts[key] = task
        let result = await task.value
        pendingStarts[key] = nil
        if case .success(let client) = result {
            clients[key] = client
            await client.setClosedHandler { [weak self] in
                Task { await self?.forget(key: key, client: client) }
            }
        }
        return result
    }

    /// 服务器自行退出后清理登记,下次打开文档会重新启动。
    private func forget(key: String, client: LSPClient) {
        if clients[key] === client { clients[key] = nil }
    }

    /// 超出上限时回收最久未用且没有打开文档的服务器(`keeping` 与有打开文档的不回收)。
    private func evictIfNeeded(keeping: String?) async {
        guard maxClients > 0 else { return }
        while clients.count > maxClients {
            var candidates: [(key: String, used: Date)] = []
            for (key, client) in clients where key != keeping {
                if await client.openDocumentCount == 0 { candidates.append((key, lastUsed[key] ?? .distantPast)) }
            }
            guard let victim = candidates.min(by: { $0.used < $1.used }), let client = clients[victim.key] else { return }
            clients[victim.key] = nil
            idleTasks[victim.key]?.cancel()
            idleTasks[victim.key] = nil
            Log.lsp.info("语言服务器超出上限被回收", ["key": victim.key, "max": String(maxClients)])
            await client.shutdown()
        }
    }

    private func recycleIfIdle(key: String) async {
        idleTasks[key] = nil
        guard let client = clients[key], await client.openDocumentCount == 0 else { return }
        clients[key] = nil
        Log.lsp.info("语言服务器空闲回收", ["key": key])
        await client.shutdown()
    }
}
