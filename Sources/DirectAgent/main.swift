// @author ygw
// DirectAgent 可执行文件:在 stdin/stdout 上运行直连兜底 ACP Agent(`claude -p` stream-json)。
// 环境变量 OMA_CLAUDE_PATH 指定 claude 路径。

import ACPKit
import AgentHost
import Foundation

guard let claude = ProcessInfo.processInfo.environment["OMA_CLAUDE_PATH"], !claude.isEmpty else {
    FileHandle.standardError.write(Data("缺少环境变量 OMA_CLAUDE_PATH\n".utf8))
    exit(2)
}
let agent = ClaudeDirectAgent(transport: StdioServerTransport(), claudePath: claude, onClose: { exit(0) })
try await agent.start()
while true { try await Task.sleep(for: .seconds(3600)) }
