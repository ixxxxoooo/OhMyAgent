// @author ygw
// Agent 监督者:拉起子进程、完成握手、监测退出,并向上层提供状态流。

import ACPKit
import Foundation
import OMLog

/// 监督者状态。
public enum AgentState: Sendable {
    case idle
    case starting
    case ready(InitializeResult)
    case failed(String)
    case exited(code: Int32?)
}

/// 每个 Workspace 窗口一个监督者,独占一个 Agent 子进程。
public actor AgentSupervisor {
    public let provider: any AgentProvider
    public let cwd: String
    private let delegate: any ACPClientDelegate
    private let advertiseFileSystem: Bool
    private let advertiseTerminal: Bool
    private let extraCapabilities: [String: JSONValue]
    private var transport: StdioTransport?
    public private(set) var client: ACPClient?
    public private(set) var state: AgentState = .idle
    public private(set) var initializeResult: InitializeResult?

    /// 状态变化流。
    public nonisolated let states: AsyncStream<AgentState>
    private let stateContinuation: AsyncStream<AgentState>.Continuation

    /// 创建监督者。
    /// - Parameters:
    ///   - provider: Agent 提供者
    ///   - cwd: 工作目录
    ///   - delegate: 反向请求委托
    ///   - fileSystem: 是否向 Agent 声明 `fs` 能力(需委托实现读写)
    ///   - terminal: 是否向 Agent 声明 `terminal` 能力(需委托实现终端)
    ///   - extraCapabilities: 其它客户端能力(如 `elicitation`)
    public init(provider: any AgentProvider, cwd: String, delegate: any ACPClientDelegate, fileSystem: Bool = false, terminal: Bool = false, extraCapabilities: [String: JSONValue] = [:]) {
        self.extraCapabilities = extraCapabilities
        self.advertiseFileSystem = fileSystem
        self.advertiseTerminal = terminal
        self.provider = provider
        self.cwd = cwd
        self.delegate = delegate
        let (stream, continuation) = AsyncStream<AgentState>.makeStream(bufferingPolicy: .bufferingNewest(8))
        self.states = stream
        self.stateContinuation = continuation
    }

    /// 子进程 pid(诊断用)。
    public var processIdentifier: Int32? { transport?.processIdentifier }

    private func set(_ new: AgentState) {
        state = new
        stateContinuation.yield(new)
    }

    /// 启动子进程并完成 `initialize`。
    /// - Parameter tools: 工具定位结果
    /// - Returns: 握手结果
    @discardableResult
    public func start(tools: LocatedTools) async throws -> InitializeResult {
        if let initializeResult, case .ready = state { return initializeResult }
        set(.starting)
        do {
            let launch = try provider.makeLaunch(cwd: cwd, tools: tools)
            let transport = StdioTransport(launch: launch)
            let client = ACPClient(transport: transport, delegate: delegate)
            try await client.start()
            self.transport = transport
            self.client = client
            let result = try await client.initialize(fileSystem: advertiseFileSystem, terminal: advertiseTerminal, extraCapabilities: extraCapabilities)
            initializeResult = result
            Log.agent.info("ACP 握手完成", ["agent": result.agentName, "version": result.agentVersion ?? "-", "authMethods": "\(result.authMethods.count)"])
            set(.ready(result))
            return result
        } catch {
            Log.agent.error("Agent 启动失败", error: error, ["cwd": cwd])
            set(.failed(error.localizedDescription))
            throw error
        }
    }

    /// 监听进程退出并更新状态,调用方在拿到 `client.events` 后转交 `closed` 事件。
    public func noteExited(code: Int32?) {
        set(.exited(code: code))
        client = nil
        transport = nil
        initializeResult = nil
    }

    /// 停止子进程并回收。
    public func stop() async {
        Log.agent.info("停止 Agent", ["cwd": cwd])
        if let client { await client.close() }
        client = nil
        transport = nil
        initializeResult = nil
        set(.idle)
    }
}
