// @author ixxxxoooo
// ACP 集成验证工具:定位工具链、完成握手;带 `--prompt "文本"` 时对真实适配器跑一轮完整对话。
// 用法: ACPSpike [--prompt "只回复 OK"] [--cwd /path]

import ACPKit
import AgentHost
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)
let args = CommandLine.arguments
func option(_ name: String) -> String? {
    guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
    return args[index + 1]
}
let promptText = option("--prompt")
let cwd = option("--cwd") ?? FileManager.default.currentDirectoryPath

/// 自动允许一次的委托(仅用于验证工具)。
struct AutoAllow: ACPClientDelegate {
    func requestPermission(_ request: PermissionRequest) async -> PermissionOutcome {
        print("[permission] 自动允许: \(request.toolCallRaw["title"]?.stringValue ?? request.toolCallId)")
        return .selected(optionId: request.options.first { $0.kind == .allowOnce }?.optionId ?? request.options.first?.optionId ?? "")
    }
}

let clock = ContinuousClock()
let t0 = clock.now
let env = await ShellEnvironment.resolve()
print("[env] 解析登录 shell 环境: \(clock.now - t0)")
let tools = ExecutableLocator.locate(projectRoot: FileManager.default.currentDirectoryPath, environment: env)
print("[tools] node=\(tools.nodePath ?? "-") (\(tools.nodeVersion ?? "-")) claude=\(tools.claudePath ?? "-")")
print("[tools] adapter=\(tools.adapterEntry ?? "-")")

let supervisor = AgentSupervisor(provider: ClaudeACPProvider(), cwd: cwd, delegate: AutoAllow())
do {
    let t1 = clock.now
    let result = try await supervisor.start(tools: tools)
    print("[initialize] \(clock.now - t1) agent=\(result.agentTitle ?? result.agentName) v\(result.agentVersion ?? "?") caps(list=\(result.capabilities.canList), fork=\(result.capabilities.canFork), resume=\(result.capabilities.canResume), steer=\(result.capabilities.canSteer), image=\(result.capabilities.imagePrompts))")
    guard let client = await supervisor.client else { exit(1) }

    let t2 = clock.now
    let setup = try await client.newSession(cwd: cwd)
    print("[session/new] \(clock.now - t2) id=\(setup.sessionId) options=\(setup.configOptions.map { "\($0.id)=\($0.currentDisplayName)" })")

    if let promptText {
        let eventTask = Task {
            var thoughts = 0, chunks = 0
            for await event in client.events {
                switch event {
                case .sessionUpdate(_, let update):
                    switch update {
                    case .agentThoughtChunk(_, let c): thoughts += 1; print("[thought] \(c.plainText ?? "")", terminator: "")
                    case .agentMessageChunk(_, let c): chunks += 1; print(c.plainText ?? "", terminator: "")
                    case .toolCall(let call): print("\n[tool_call] \(call.kind.rawValue) \(call.title) \(call.status.rawValue)")
                    case .toolCallUpdate(let id, let raw): print("\n[tool_update] \(id) \(raw["status"]?.stringValue ?? "")")
                    case .usage(let usage): print("\n[usage] used=\(usage.used ?? 0) size=\(usage.size ?? 0) cost=\(usage.costAmount ?? 0)")
                    case .plan(let entries): print("\n[plan] \(entries.count) 项")
                    case .availableCommands(let commands): print("[commands] \(commands.count) 个: " + commands.map(\.name).joined(separator: ", "))
                    default: break
                    }
                case .closed: return (thoughts, chunks)
                default: break
                }
            }
            return (thoughts, chunks)
        }
        let t3 = clock.now
        let stop = try await client.prompt(sessionId: setup.sessionId, content: [.text(promptText)])
        print("\n[prompt] 完成 stopReason=\(stop.rawValue) 耗时 \(clock.now - t3)")
        eventTask.cancel()
    }
    await supervisor.stop()
} catch {
    print("失败: \(error.localizedDescription)")
    exit(1)
}
