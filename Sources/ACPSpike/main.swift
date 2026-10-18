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
        let raw = String(describing: request.raw)
        print("[permission] \(request.toolCallRaw["title"]?.stringValue ?? request.toolCallId) 选项=\(request.options.map { "\($0.optionId)(\($0.kind.rawValue)):\($0.name)" })")
        print("[permission-raw] \(raw.prefix(4000))")
        // 验证「编辑计划文件后再批准」是否生效:ACPSPIKE_EDIT_PLAN 非空时,在批准前往计划文件追加一行额外要求并放行
        if let extra = ProcessInfo.processInfo.environment["ACPSPIKE_EDIT_PLAN"], !extra.isEmpty,
           let path = request.toolCallRaw["rawInput"]?["planFilePath"]?.stringValue,
           let allow = request.options.first(where: { $0.optionId == "exit-plan-default" }) {
            let old = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            try? (old + "\n\n" + extra + "\n").write(toFile: path, atomically: true, encoding: .utf8)
            print("[plan-edited] 已向 \(path) 追加:\(extra)")
            return .selected(optionId: allow.optionId)
        }
        // 计划批准(ExitPlanMode)不放行:只为观察计划模式发出的内容,避免真的去执行
        if request.toolCallRaw["rawInput"]?["plan"] != nil || request.toolCallRaw["title"]?.stringValue?.contains("plan") == true,
           let reject = request.options.first(where: { $0.kind == .rejectOnce }) {
            return .selected(optionId: reject.optionId)
        }
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

    for item in setup.configOptions {
        print("[option] \(item.id) current=\(item.currentValue.stringValue ?? "-") values=\(item.options.map { "\($0.value)=\($0.name)" })")
    }

    if let mode = option("--mode") {
        try await client.setMode(sessionId: setup.sessionId, modeId: mode)
        print("[mode] 已切换到 \(mode)")
    }

    if let promptText {
        let eventTask = Task {
            var thoughts = 0, chunks = 0
            for await event in client.events {
                switch event {
                case .sessionUpdate(_, let update):
                    switch update {
                    case .agentThoughtChunk(_, let c): thoughts += 1; print("[thought] \(c.plainText ?? "")", terminator: "")
                    case .agentMessageChunk(_, let c): chunks += 1; print(c.plainText ?? "", terminator: "")
                    case .toolCall(let call): print("\n[tool_call] name=\(call.name ?? "-") kind=\(call.kind.rawValue) title=\(call.title) status=\(call.status.rawValue) input=\(String(describing: call.rawInput).prefix(300))")
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
