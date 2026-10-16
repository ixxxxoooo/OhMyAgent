// @author ixxxxoooo
// 脚本化 Agent 的演示历史会话支持:`session/list` 返回预置目录,`session/load` 无停顿回放完整内容。

import Foundation

extension ScriptedAgent {
    /// 演示模式的会话列表:该项目的预置历史 + 当前进程里新建的会话。
    /// - Parameter cwd: 请求的工作目录(取最后一级作为演示项目名)
    func demoSessionList(cwd: String?) -> JSONValue {
        let project = cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
        let now = Date()
        var list: [JSONValue] = DemoHistory.sessions(forProject: project).map { item in
            ["sessionId": .string(item.id), "cwd": .string(cwd ?? "/"), "title": .string(item.title), "updatedAt": .string(item.updatedAt(now: now))]
        }
        let known = Set(DemoHistory.all.map(\.id))
        for id in sessions.keys.sorted() where !known.contains(id) {
            list.append(["sessionId": .string(id), "cwd": .string(sessions[id] ?? "/"), "title": .string("脚本会话 \(id)"), "updatedAt": .string(ISO8601DateFormatter().string(from: now))])
        }
        return ["sessions": .array(list)]
    }

    /// 回放一条演示历史会话(无停顿,所有工具与子 Agent 均为终态)。
    /// - Parameters:
    ///   - history: 历史会话
    ///   - cwd: 会话工作目录
    func replayDemoHistory(_ history: DemoHistorySession, cwd: String) async {
        let sessionId = history.id
        replaying.insert(sessionId)
        defer { replaying.remove(sessionId) }
        let ctx = ScenarioContext(cwd: cwd, sessionId: sessionId, idSuffix: "")
        _ = try? await runSteps(DemoHistory.replaySteps(for: history, ctx: ctx), ctx: ctx)
    }
}
