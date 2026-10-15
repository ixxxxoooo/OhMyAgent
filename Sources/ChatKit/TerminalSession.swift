// @author ygw
// 终端会话视图模型:在命令运行期间以 150ms 间隔拉取输出快照,结束后停止轮询。

import ACPKit
import AgentHost
import Foundation
import Observation

/// 终端会话(供工具卡片中的终端视图使用)。
@MainActor
@Observable
public final class TerminalSession: Identifiable {
    public nonisolated let id: String
    public let command: String
    public private(set) var output = ""
    public private(set) var truncated = false
    public private(set) var exitCode: Int?
    public private(set) var signal: String?
    public private(set) var isRunning = true
    private var pollTask: Task<Void, Never>?

    init(id: String, command: String) {
        self.id = id
        self.command = command
    }

    /// 开始轮询。
    /// - Parameter manager: 终端管理器
    func startPolling(manager: TerminalManager) {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                let snapshot = await manager.peek(self?.id ?? "")
                guard let self else { return }
                guard let snapshot else { self.isRunning = false; return }
                self.apply(snapshot)
                if snapshot.exitCode != nil || snapshot.signal != nil { self.isRunning = false; return }
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
    }

    private func apply(_ snapshot: TerminalOutputSnapshot) {
        if output != snapshot.output { output = snapshot.output }
        truncated = snapshot.truncated
        exitCode = snapshot.exitCode
        signal = snapshot.signal
    }

    /// 停止轮询。
    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }
}
