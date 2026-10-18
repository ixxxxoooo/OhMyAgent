// @author ixxxxoooo
// 斜杠命令体检:目录里的每个客户端命令都有对应的处理;经实测不可用的内置命令不进补全、手动输入有说明;内部命令在补全里隐藏。

import Foundation
import Testing
import ACPKit
@testable import ChatKit

@Suite("斜杠命令体检")
struct SlashCommandAuditTests {
    @Test("客户端命令目录里的每个命令都能被解析(带参数命令用示例参数)")
    func everyCatalogCommandParses() {
        let samples: [String: String] = ["best-of-n": "a,b 任务", "mcp": ""]
        for spec in LocalCommands.catalog {
            let text = "/\(spec.name)" + (samples[spec.name].map { $0.isEmpty ? "" : " " + $0 } ?? "")
            #expect(LocalCommands.parse(text) != nil, "\(text) 没有对应的客户端处理")
        }
    }

    @Test("不可用的内置命令:解析为 unsupported,不在静态清单与客户端目录里,且都有说明")
    func unsupportedCommands() {
        let staticNames = Set(ClaudeBuiltinCommands.catalog.map(\.name))
        let localNames = LocalCommands.names
        for (name, notice) in ClaudeBuiltinCommands.unsupported {
            #expect(LocalCommands.parse("/\(name)") == .unsupported(name: name))
            #expect(!staticNames.contains(name) && !localNames.contains(name), "\(name) 不该出现在补全清单里")
            #expect(!notice.isEmpty)
        }
        #expect(LocalCommands.parse("/not-a-real-command") == nil)
    }

    @Test("补全隐藏内部命令与 SDK 下不可用的命令,正常命令保留")
    func completionHidesInternal() {
        let commands = [
            AvailableCommand(name: "__remote-workflow", description: "内部", inputHint: nil),
            AvailableCommand(name: "workflow-launch-exec", description: "内部", inputHint: nil),
            AvailableCommand(name: "fast", description: "快速模式", inputHint: nil),
            AvailableCommand(name: "compact", description: "压缩", inputHint: nil),
        ]
        let titles = CompletionEngine.slashItems(query: "", agentCommands: commands).map(\.insertText)
        #expect(titles.contains("/compact"))
        #expect(!titles.contains("/__remote-workflow") && !titles.contains("/workflow-launch-exec") && !titles.contains("/fast"))
    }
}
