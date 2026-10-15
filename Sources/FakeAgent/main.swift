// @author ygw
// FakeAgent 可执行文件:在 stdin/stdout 上运行脚本化 ACP Agent,用于集成测试与离线演示。

import ACPKit
import Foundation

let agent = ScriptedAgent(transport: StdioServerTransport(), onClose: { exit(0) })
try await agent.start()
// 阻塞直到 stdin 关闭(onClose 会退出进程)
while true { try await Task.sleep(for: .seconds(3600)) }
