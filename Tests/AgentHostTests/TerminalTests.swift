// @author ixxxxoooo
// TerminalManager 测试:真实子进程的输出捕获、退出码、截断、终止。

import Foundation
import Testing

@testable import AgentHost

@Suite("终端管理器")
struct TerminalManagerTests {
    private func manager() -> TerminalManager {
        TerminalManager(workspace: NSTemporaryDirectory())
    }

    @Test("捕获 stdout 与 stderr 并返回退出码")
    func capturesOutput() async throws {
        let terminals = manager()
        let id = try await terminals.create(command: "sh", args: ["-c", "echo hello; echo oops 1>&2; exit 3"], env: [:], cwd: nil, outputByteLimit: nil)
        let final = try await terminals.waitForExit(id)
        #expect(final.output.contains("hello"))
        #expect(final.output.contains("oops"))
        #expect(final.exitCode == 3)
        #expect(final.truncated == false)
    }

    @Test("输出超过上限时保留尾部并标记截断")
    func truncates() async throws {
        let terminals = manager()
        let id = try await terminals.create(command: "sh", args: ["-c", "i=0; while [ $i -lt 4000 ]; do echo line-$i; i=$((i+1)); done"], env: [:], cwd: nil, outputByteLimit: 2048)
        let final = try await terminals.waitForExit(id)
        #expect(final.truncated)
        #expect(final.output.utf8.count <= 2048)
        #expect(final.output.contains("line-3999"))
        #expect(!final.output.contains("line-0\n"))
    }

    @Test("kill 终止长时间运行的进程")
    func kill() async throws {
        let terminals = manager()
        let id = try await terminals.create(command: "sleep", args: ["30"], env: [:], cwd: nil, outputByteLimit: nil)
        try await terminals.kill(id)
        let final = try await terminals.waitForExit(id)
        #expect(final.exitCode == nil)
        #expect(final.signal != nil)
    }

    @Test("环境变量与工作目录生效,未知终端报错")
    func envAndErrors() async throws {
        let terminals = manager()
        let id = try await terminals.create(command: "sh", args: ["-c", "echo $OMA_TEST; pwd"], env: ["OMA_TEST": "值"], cwd: "/tmp", outputByteLimit: nil)
        let final = try await terminals.waitForExit(id)
        #expect(final.output.contains("值"))
        #expect(final.output.contains("/tmp"))
        await #expect(throws: (any Error).self) { try await terminals.output("不存在") }
        try await terminals.release(id)
        await #expect(throws: (any Error).self) { try await terminals.output(id) }
    }
}
