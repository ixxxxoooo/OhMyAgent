// @author ygw
// 性能基线测试:JSON-RPC 分帧与解码吞吐(预算:单连接 ≥ 5 MB/s)。
// 测试以 debug 构建运行,阈值取预算并留余量;`swift test -c release` 可得到更接近发布版的数据。

import Foundation
import Testing
@testable import ACPKit

@Suite("性能基线")
struct PerformanceTests {
    /// 构造约 `megabytes` MB 的 session/update 通知流(每行约 600 字节)。
    private func makeStream(megabytes: Int) -> Data {
        let text = String(repeating: "流式文本片段 streaming chunk ", count: 12)
        let line = #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"\#(text)"}}}}"# + "\n"
        let bytes = Data(line.utf8)
        var data = Data()
        data.reserveCapacity(megabytes * 1_048_576 + bytes.count)
        while data.count < megabytes * 1_048_576 { data.append(bytes) }
        return data
    }

    @Test("分帧+解码吞吐 ≥ 5 MB/s(64KB 分块)")
    func framingAndDecodeThroughput() throws {
        let stream = makeStream(megabytes: 20)
        var framer = LineFramer()
        var count = 0
        let clock = ContinuousClock()
        let elapsed = try clock.measure {
            var offset = 0
            while offset < stream.count {
                let end = min(offset + 65_536, stream.count)
                for line in framer.push(stream.subdata(in: offset..<end)) {
                    _ = try JSONRPCMessage.parse(line)
                    count += 1
                }
                offset = end
            }
        }
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let throughput = 20.0 / seconds
        print("【基线】解码吞吐 \(String(format: "%.1f", throughput)) MB/s,共 \(count) 条")
        #expect(throughput >= 5)
    }

    @Test("一次性喂入大块数据(2MB)分帧不退化为平方复杂度")
    func hugeChunkFraming() {
        let stream = makeStream(megabytes: 2)
        var framer = LineFramer()
        let clock = ContinuousClock()
        var lines = 0
        let elapsed = clock.measure { lines = framer.push(stream).count }
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        print("【基线】2MB 单块分帧 \(String(format: "%.3f", seconds))s,\(lines) 行")
        #expect(seconds < 0.5)
    }
}
