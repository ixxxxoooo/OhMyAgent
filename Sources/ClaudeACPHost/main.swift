// @author ixxxxoooo
// 开发/验证用:把原生 Claude 适配器挂在 stdio 上(与 Node 版 claude-agent-acp 同形),
// 供 `Scripts/acp-diff.py` 做差分对照与外部 ACP 客户端联调。不随应用分发。
// 用法: ClaudeACPHost [--claude /path/to/claude]

import ACPKit
import ClaudeAgentKit
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)
let args = CommandLine.arguments
let explicitClaude = args.firstIndex(of: "--claude").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
var environment = ProcessInfo.processInfo.environment
let claudePath = explicitClaude ?? environment["CLAUDE_CODE_EXECUTABLE"] ?? "\(NSHomeDirectory())/.local/bin/claude"
environment["CLAUDE_CODE_EXECUTABLE"] = claudePath
let config = ClaudeAgentConfig(executable: claudePath, environment: environment, version: "1.0.0")
let connection = ACPConnection(transport: StdioServerTransport(), label: "claude-acp-host")
let agent = ClaudeAcpAgent(connection: connection, config: config)
let finished = DispatchSemaphore(value: 0)
do {
    try await agent.start(onClose: { finished.signal() })
} catch {
    FileHandle.standardError.write(Data("启动失败: \(error.localizedDescription)\n".utf8))
    exit(1)
}
await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
    DispatchQueue.global().async {
        finished.wait()
        continuation.resume()
    }
}
await agent.shutdown()
