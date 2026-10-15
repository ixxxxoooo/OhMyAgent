// @author ygw
// FakeAgent 可执行文件:在 stdin/stdout 上运行脚本化 ACP Agent,用于集成测试与离线演示。

import ACPKit
import Foundation

/// 基于当前进程 stdin/stdout 的传输(Agent 侧)。
final class StdioServerTransport: ACPTransport, @unchecked Sendable {
    private let writeQueue = DispatchQueue(label: "FakeAgent.write")

    func start() throws -> AsyncStream<TransportEvent> {
        let (stream, continuation) = AsyncStream<TransportEvent>.makeStream(bufferingPolicy: .unbounded)
        let thread = Thread {
            var framer = LineFramer()
            let input = FileHandle.standardInput
            while true {
                let data = input.availableData
                if data.isEmpty { break }
                for line in framer.push(data) { continuation.yield(.line(line)) }
            }
            continuation.yield(.closed(exitCode: 0))
            continuation.finish()
        }
        thread.start()
        return stream
    }

    func send(_ data: Data) {
        var payload = data
        payload.append(0x0A)
        let framed = payload
        writeQueue.async { FileHandle.standardOutput.write(framed) }
    }

    func stop() {}
}

let agent = ScriptedAgent(transport: StdioServerTransport(), onClose: { exit(0) })
try await agent.start()
// 阻塞直到 stdin 关闭(onClose 会退出进程)
while true { try await Task.sleep(for: .seconds(3600)) }
