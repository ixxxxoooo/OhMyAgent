// @author ygw
// ClaudeConfigKit 测试:全部使用临时目录作为 home 与工作区,不触碰真实配置。

import Foundation
import Testing
@testable import ClaudeConfigKit

/// 临时环境。
struct Sandbox {
    let root: URL
    let home: URL
    let workspace: URL
    var paths: ClaudePaths { ClaudePaths(home: home, workspace: workspace) }

    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("oma-cfg-\(UUID().uuidString)")
        home = root.appendingPathComponent("home")
        workspace = root.appendingPathComponent("ws")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }

    func write(_ text: String, to relative: String, base: URL? = nil) throws {
        let url = (base ?? root).appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}

@Suite("JSON 文件与设置")
struct JSONSettingsTests {
    @Test("读-改-写保留未知字段,并生成备份")
    func preservesUnknownKeys() throws {
        let box = try Sandbox(); defer { box.cleanup() }
        try box.write(#"{"model":"opus","custom":{"a":1,"b":[1,2]},"flag":true}"#, to: ".claude/settings.json", base: box.home)
        let store = SettingsStore(paths: box.paths)
        try store.set(["permissions", "defaultMode"], to: "plan", in: .user)
        let object = try JSONFile(box.paths.userSettings).read()
        #expect(object["model"] as? String == "opus")
        #expect((object["custom"] as? [String: Any])?["a"] as? Int == 1)
        #expect(object["flag"] as? Bool == true)
        #expect(JSONPath.get(object, ["permissions", "defaultMode"]) as? String == "plan")
        #expect(FileManager.default.fileExists(atPath: box.home.appendingPathComponent(".claude/settings.json.oma-backup").path))
    }

    @Test("删除键时清理变空的父级,生效值按 本地>项目>用户")
    func removalAndPrecedence() throws {
        let box = try Sandbox(); defer { box.cleanup() }
        let store = SettingsStore(paths: box.paths)
        try store.set(["a", "b"], to: 1, in: .user)
        try store.set(["a", "b"], to: nil, in: .user)
        #expect(try JSONFile(box.paths.userSettings).read()["a"] == nil)
        try store.set(["model"], to: "user", in: .user)
        try store.set(["model"], to: "project", in: .project)
        #expect(store.effectiveValue(["model"])?.scope == .project)
        try store.set(["model"], to: "local", in: .local)
        #expect(store.effectiveValue(["model"])?.value as? String == "local")
    }

    @Test("损坏的 JSON 报错且不会被覆盖")
    func invalidJSON() throws {
        let box = try Sandbox(); defer { box.cleanup() }
        try box.write("{ broken", to: ".claude/settings.json", base: box.home)
        #expect(throws: ConfigError.self) { try SettingsStore(paths: box.paths).set(["x"], to: 1, in: .user) }
        #expect(try String(contentsOf: box.paths.userSettings, encoding: .utf8) == "{ broken")
    }

    @Test("没有工作区时写项目层被拒绝")
    func noWorkspace() throws {
        let box = try Sandbox(); defer { box.cleanup() }
        let store = SettingsStore(paths: ClaudePaths(home: box.home, workspace: nil))
        #expect(throws: ConfigError.self) { try store.set(["x"], to: 1, in: .project) }
    }
}

@Suite("MCP 存储")
struct MCPStoreTests {
    @Test("三个作用域的增删改与覆盖关系")
    func scopesAndOverride() throws {
        let box = try Sandbox(); defer { box.cleanup() }
        try box.write(#"{"numStartups":3,"mcpServers":{"fs":{"type":"stdio","command":"old"}}}"#, to: ".claude.json", base: box.home)
        let store = MCPStore(paths: box.paths)
        try store.save(MCPServerConfig(name: "fs", command: "npx", args: ["-y", "server"], env: ["K": "v"]), scope: .project)
        try store.save(MCPServerConfig(name: "web", transport: .http, url: "https://example.com/mcp", headers: ["Authorization": "Bearer x"]), scope: .local)
        let entries = try store.list()
        #expect(entries.count == 3)
        let user = try #require(entries.first { $0.scope == .user })
        #expect(user.overriddenBy == .project)
        #expect(entries.first { $0.scope == .project }?.overriddenBy == nil)
        #expect(entries.first { $0.config.name == "web" }?.config.transport == .http)
        // ~/.claude.json 中的无关字段保持不变
        #expect(try JSONFile(box.paths.claudeJSON).read()["numStartups"] as? Int == 3)

        try store.remove(name: "fs", scope: .project)
        #expect(try store.list().filter { $0.config.name == "fs" }.count == 1)
        #expect(throws: ConfigError.self) { try store.remove(name: "ghost", scope: .user) }
    }

    @Test("编辑保留服务器上的未知字段,重命名会移除旧名")
    func editKeepsExtras() throws {
        let box = try Sandbox(); defer { box.cleanup() }
        try box.write(#"{"mcpServers":{"a":{"type":"stdio","command":"x","timeout":9000}}}"#, to: ".mcp.json", base: box.workspace)
        let store = MCPStore(paths: box.paths)
        try store.save(MCPServerConfig(name: "b", command: "y"), scope: .project, replacing: "a")
        let servers = try JSONFile(box.paths.projectMCP!).read()["mcpServers"] as? [String: Any]
        #expect(servers?["a"] == nil)
        #expect((servers?["b"] as? [String: Any])?["command"] as? String == "y")
        try store.save(MCPServerConfig(name: "b", command: "z"), scope: .project)
        #expect(((try JSONFile(box.paths.projectMCP!).read()["mcpServers"] as? [String: Any])?["b"] as? [String: Any])?["command"] as? String == "z")
    }

    @Test("校验:名称、命令、URL 协议")
    func validation() {
        #expect(MCPStore.validate(MCPServerConfig(name: "ok", command: "npx")).isEmpty)
        #expect(!MCPStore.validate(MCPServerConfig(name: "bad name", command: "npx")).isEmpty)
        #expect(!MCPStore.validate(MCPServerConfig(name: "x", command: " ")).isEmpty)
        #expect(!MCPStore.validate(MCPServerConfig(name: "x", transport: .http, url: "ftp://a")).isEmpty)
        #expect(MCPStore.validate(MCPServerConfig(name: "x", transport: .ws, url: "wss://a/b")).isEmpty)
    }

    @Test("add-json 支持仅含 url 的简写并拒绝非法 JSON")
    func addJSON() throws {
        let box = try Sandbox(); defer { box.cleanup() }
        let store = MCPStore(paths: box.paths)
        try store.addJSON(name: "remote", json: #"{"url":"https://a.b/mcp"}"#, scope: .user)
        #expect(try store.list().first?.config.transport == .http)
        #expect(throws: ConfigError.self) { try store.addJSON(name: "x", json: "[1]", scope: .user) }
        #expect(throws: ConfigError.self) { try store.addJSON(name: "x", json: #"{"command":""}"#, scope: .user) }
    }

    @Test("项目级服务器需要批准,批准后可禁用")
    func approvalAndDisable() throws {
        let box = try Sandbox(); defer { box.cleanup() }
        try box.write(#"{"mcpServers":{"p":{"command":"x"}}}"#, to: ".mcp.json", base: box.workspace)
        let store = MCPStore(paths: box.paths)
        #expect(try store.list().first?.needsApproval == true)
        try store.approveProjectServer(name: "p")
        #expect(try store.list().first?.needsApproval == false)
        try store.setEnabled(false, name: "p", scope: .project)
        let entry = try #require(try store.list().first)
        #expect(entry.isDisabled)
        #expect(!entry.needsApproval)

        try store.save(MCPServerConfig(name: "u", command: "c"), scope: .user)
        try store.setEnabled(false, name: "u", scope: .user)
        #expect(try store.list().first { $0.config.name == "u" }?.isDisabled == true)
        try store.setEnabled(true, name: "u", scope: .user)
        #expect(try store.list().first { $0.config.name == "u" }?.isDisabled == false)
    }

    @Test("未解析的 ${VAR} 提示;带默认值的不报")
    func variables() {
        let config = MCPServerConfig(name: "x", transport: .http, url: "https://${HOST}/mcp", headers: ["A": "Bearer ${TOKEN}", "B": "${REGION:-us}"])
        #expect(MCPStore.unresolvedVariables(in: config, environment: ["HOST": "h"]) == ["TOKEN"])
    }

    @Test("解析 claude mcp list 输出")
    func parseHealth() {
        let output = """
        Checking MCP server health...

        fs: npx -y server - ✓ Connected
        web: https://a.b/mcp (HTTP) - ! Needs authentication
        bad: node x.js - ✗ Failed to connect
        """
        let result = MCPStore.parseHealth(output)
        #expect(result.map(\.state) == [.connected, .needsAuth, .failed])
        #expect(result.map(\.name) == ["fs", "web", "bad"])
    }
}

@Suite("Frontmatter")
struct FrontmatterTests {
    @Test("读取标量、布尔、列表与块标量")
    func reading() {
        let text = """
        ---
        name: demo
        description: "含: 冒号的描述"
        disable-model-invocation: true
        tools: [Read, Grep]
        allowed:
          - Bash
          - Edit
        notes: |
          第一行
          第二行
        ---
        正文
        """
        let doc = MarkdownDocument(parsing: text)
        #expect(doc.value("name") == "demo")
        #expect(doc.value("description") == "含: 冒号的描述")
        #expect(doc.bool("disable-model-invocation") == true)
        #expect(doc.list("tools") == ["Read", "Grep"])
        #expect(doc.list("allowed") == ["Bash", "Edit"])
        #expect(doc.value("notes") == "第一行\n第二行")
        #expect(doc.body == "正文")
    }

    @Test("修改已知字段时保留未知字段与注释,往返稳定")
    func editingPreservesRest() {
        let text = "---\n# 注释\nname: a\nhooks:\n  PreToolUse:\n    - x\nunknown: 1\n---\nbody\n"
        var doc = MarkdownDocument(parsing: text)
        #expect(doc.render() == text)
        doc.setValue("name", "b: c")
        doc.setBool("user-invocable", false)
        doc.setValue("unknown", nil)
        let out = doc.render()
        #expect(out.contains("# 注释"))
        #expect(out.contains("hooks:\n  PreToolUse:\n    - x"))
        #expect(out.contains("name: \"b: c\""))
        #expect(out.contains("user-invocable: false"))
        #expect(!out.contains("unknown"))
        #expect(MarkdownDocument(parsing: out).value("name") == "b: c")
    }

    @Test("没有 frontmatter 的文档与新建字段")
    func noFrontmatter() {
        var doc = MarkdownDocument(parsing: "# 标题\n内容")
        #expect(!doc.hasFrontmatter)
        #expect(doc.render() == "# 标题\n内容")
        doc.setValue("description", "说明")
        #expect(doc.render() == "---\ndescription: 说明\n---\n# 标题\n内容")
    }

    @Test("多行值写成块标量并可读回")
    func multiline() {
        var doc = MarkdownDocument(body: "x")
        doc.setValue("when_to_use", "a\nb")
        #expect(MarkdownDocument(parsing: doc.render()).value("when_to_use") == "a\nb")
        doc.setList("tools", ["Read", "Bash(git:*)"])
        #expect(MarkdownDocument(parsing: doc.render()).list("tools") == ["Read", "Bash(git:*)"])
    }
}

@Suite("Skills、命令与 Subagents")
struct SkillAgentTests {
    @Test("创建模板、列表、覆盖关系、保存与删除")
    func skillLifecycle() throws {
        let box = try Sandbox(); defer { box.cleanup() }
        let store = SkillStore(paths: box.paths)
        try store.create(name: "review", description: "审查代码", template: .manual, scope: .user)
        try store.create(name: "review", description: "项目版本", template: .automatic, scope: .project)
        try store.create(name: "explore", description: "探索", template: .fork, scope: .project)
        try box.write("---\ndescription: 提交\n---\n提交代码", to: ".claude/commands/commit.md", base: box.workspace)

        var items = store.list()
        #expect(items.count == 4)
        let user = try #require(items.first { $0.name == "review" && $0.source == .scope(.user) })
        let project = try #require(items.first { $0.name == "review" && $0.source == .scope(.project) })
        #expect(user.disableModelInvocation)
        #expect(project.overriddenBy == .scope(.user))
        #expect(user.overriddenBy == nil)
        #expect(items.first { $0.name == "commit" }?.kind == .command)

        var doc = try store.load(project)
        doc.setValue("description", "新的描述")
        try store.save(doc, to: project)
        #expect(store.list().first { $0.id == project.id }?.description == "新的描述")

        try store.delete(project)
        items = store.list()
        #expect(items.count == 3)
        #expect(!FileManager.default.fileExists(atPath: project.directoryURL!.path))
    }

    @Test("名称非法或重复时拒绝,符号链接目录被识别")
    func validationAndSymlink() throws {
        let box = try Sandbox(); defer { box.cleanup() }
        let store = SkillStore(paths: box.paths)
        #expect(throws: ConfigError.self) { try store.create(name: "Bad Name", description: "", template: .manual, scope: .user) }
        try store.create(name: "dup", description: "d", template: .manual, scope: .user)
        #expect(throws: ConfigError.alreadyExists("dup")) { try store.create(name: "dup", description: "d", template: .manual, scope: .user) }

        try box.write("---\nname: linked\ndescription: 链接\n---\nx", to: "elsewhere/linked/SKILL.md")
        try FileManager.default.createSymbolicLink(at: box.home.appendingPathComponent(".claude/skills/linked"),
                                                   withDestinationURL: box.root.appendingPathComponent("elsewhere/linked"))
        let linked = try #require(store.list().first { $0.name == "linked" })
        #expect(linked.isSymlink)
    }

    @Test("插件内的 Skill 带命名空间且只读")
    func pluginSkills() throws {
        let box = try Sandbox(); defer { box.cleanup() }
        try box.write("---\ndescription: 插件技能\n---\nx", to: "plug/skills/hello/SKILL.md")
        let store = SkillStore(paths: box.paths, pluginRoots: ["demo": box.root.appendingPathComponent("plug")])
        let item = try #require(store.list().first)
        #expect(item.name == "demo:hello")
        #expect(item.source.isReadOnly)
        #expect(throws: ConfigError.self) { try store.save(MarkdownDocument(body: ""), to: item) }
        #expect(throws: ConfigError.self) { try store.delete(item) }
    }

    @Test("Subagent 创建、列表与项目覆盖用户")
    func agents() throws {
        let box = try Sandbox(); defer { box.cleanup() }
        let store = AgentStore(paths: box.paths)
        try store.create(name: "reviewer", description: "审查者", tools: ["Read", "Grep"], model: "sonnet", prompt: "你是审查者", scope: .user)
        try store.create(name: "reviewer", description: "项目审查者", tools: [], model: nil, prompt: "", scope: .project)
        #expect(throws: ConfigError.self) { try store.create(name: "x", description: " ", tools: [], model: nil, prompt: "", scope: .user) }
        let items = store.list()
        #expect(items.count == 2)
        #expect(items.first { $0.source == .scope(.user) }?.overriddenBy == .scope(.project))
        let doc = MarkdownDocument(parsing: try String(contentsOf: items.first { $0.source == .scope(.user) }!.fileURL, encoding: .utf8))
        #expect(doc.list("tools") == ["Read", "Grep"])
        #expect(doc.value("model") == "sonnet")
        try store.delete(items[0])
        #expect(store.list().count == 1)
    }
}

@Suite("Hooks")
struct HooksStoreTests {
    @Test("添加复用同 matcher 的组、更新保留未知字段、删除后清理空结构")
    func lifecycle() throws {
        let box = try Sandbox(); defer { box.cleanup() }
        let store = HooksStore(paths: box.paths)
        try store.add(HookHandler(command: "echo a", timeout: 5), event: "PreToolUse", matcher: "Bash", scope: .project)
        try store.add(HookHandler(command: "echo b"), event: "PreToolUse", matcher: "Bash", scope: .project)
        try store.add(HookHandler(type: "http", url: "https://h.example/x"), event: "Stop", matcher: "", scope: .user)
        var entries = try store.list()
        #expect(entries.count == 3)
        #expect(entries.filter { $0.event == "PreToolUse" }.allSatisfy { $0.groupIndex == 0 })

        // 手工加入未知字段后,更新应保留
        var root = try JSONFile(box.paths.projectSettings!).read()
        var hooks = root["hooks"] as! [String: Any]
        var groups = hooks["PreToolUse"] as! [[String: Any]]
        var handlers = groups[0]["hooks"] as! [[String: Any]]
        handlers[0]["statusMessage"] = "运行中"
        groups[0]["hooks"] = handlers
        hooks["PreToolUse"] = groups
        root["hooks"] = hooks
        try JSONFile(box.paths.projectSettings!).write(root)

        entries = try store.list()
        let first = try #require(entries.first { $0.handler.command == "echo a" })
        try store.update(first, handler: HookHandler(command: "echo changed", timeout: 9), matcher: "Bash|Edit")
        let after = try JSONFile(box.paths.projectSettings!).read()
        let updated = (((after["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]])?[0])
        #expect(updated?["matcher"] as? String == "Bash|Edit")
        #expect(((updated?["hooks"] as? [[String: Any]])?[0])?["statusMessage"] as? String == "运行中")
        #expect(((updated?["hooks"] as? [[String: Any]])?[0])?["command"] as? String == "echo changed")

        for entry in try store.list().filter({ $0.origin == .settings(.project) }) { _ = entry }
        for entry in try store.list().filter({ $0.origin == .settings(.project) }).reversed() { try store.remove(entry) }
        #expect(try JSONFile(box.paths.projectSettings!).read()["hooks"] == nil)
        #expect(try store.list().count == 1)
    }

    @Test("校验事件、类型、命令、超时与 matcher 正则")
    func validation() {
        #expect(HooksStore.validate(handler: HookHandler(command: "x"), event: "Stop", matcher: "").isEmpty)
        #expect(!HooksStore.validate(handler: HookHandler(command: "x"), event: "Nope", matcher: "").isEmpty)
        #expect(!HooksStore.validate(handler: HookHandler(command: " "), event: "Stop", matcher: "").isEmpty)
        #expect(!HooksStore.validate(handler: HookHandler(command: "x", timeout: 0), event: "Stop", matcher: "").isEmpty)
        #expect(!HooksStore.validate(handler: HookHandler(command: "x"), event: "Stop", matcher: "([").isEmpty)
        #expect(!HooksStore.validate(handler: HookHandler(type: "http", url: "nope"), event: "Stop", matcher: "").isEmpty)
    }

    @Test("插件 hooks.json 只读展示")
    func pluginHooks() throws {
        let box = try Sandbox(); defer { box.cleanup() }
        try box.write(#"{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"echo hi"}]}]}}"#, to: "plug/hooks/hooks.json")
        let store = HooksStore(paths: box.paths, pluginRoots: ["demo": box.root.appendingPathComponent("plug")])
        let entry = try #require(try store.list().first)
        #expect(entry.origin == .plugin("demo"))
        #expect(throws: ConfigError.self) { try store.remove(entry) }
    }
}

@Suite("记忆文件")
struct MemoryStoreTests {
    @Test("列出标准位置、规则 paths 限定,读写与规则创建删除")
    func memory() throws {
        let box = try Sandbox(); defer { box.cleanup() }
        try box.write("# 用户记忆", to: ".claude/CLAUDE.md", base: box.home)
        try box.write("# 项目", to: "CLAUDE.md", base: box.workspace)
        try box.write("# agents", to: "AGENTS.md", base: box.workspace)
        let store = MemoryStore(paths: box.paths)
        var files = store.list()
        #expect(files.first { $0.kind == .user }?.exists == true)
        #expect(files.first { $0.kind == .local }?.exists == false)
        #expect(files.first { $0.kind == .agentsMD }?.isLoadedByDefault == false)

        let local = try #require(files.first { $0.kind == .local })
        try store.write("本地偏好", to: local)
        #expect(store.read(local) == "本地偏好")

        try store.createRule(name: "swift", scope: .project, pathFilters: ["**/*.swift"])
        files = store.list()
        let rule = try #require(files.first { $0.kind == .projectRule })
        #expect(rule.pathFilters == ["**/*.swift"])
        #expect(throws: ConfigError.self) { try store.createRule(name: "swift", scope: .project, pathFilters: []) }
        try store.deleteRule(rule)
        #expect(store.list().first { $0.kind == .projectRule } == nil)
        #expect(throws: ConfigError.self) { try store.deleteRule(local) }
    }
}

@Suite("插件")
struct PluginStoreTests {
    @Test("读取安装记录、清单、组件数量与启用状态;市场列表")
    func installedPlugins() throws {
        let box = try Sandbox(); defer { box.cleanup() }
        let install = box.home.appendingPathComponent(".claude/plugins/cache/mk/demo/1.0.0")
        try box.write(#"{"name":"demo","description":"演示","author":{"name":"ygw"}}"#, to: ".claude-plugin/plugin.json", base: install)
        try box.write("x", to: "skills/a/SKILL.md", base: install)
        try box.write("x", to: "skills/b/SKILL.md", base: install)
        try box.write("x", to: "agents/z.md", base: install)
        try box.write(#"{"mcpServers":{"m1":{"command":"x"}}}"#, to: ".mcp.json", base: install)
        try box.write(#"{"version":2,"plugins":{"demo@mk":[{"scope":"user","installPath":"\#(install.path)","version":"1.0.0"}]}}"#, to: ".claude/plugins/installed_plugins.json", base: box.home)
        try box.write(#"{"mk":{"source":{"source":"github","repo":"a/b"},"installLocation":"/x","lastUpdated":"2026-01-01"}}"#, to: ".claude/plugins/known_marketplaces.json", base: box.home)

        let store = PluginStore(paths: box.paths)
        var plugin = try #require(store.installed().first)
        #expect(plugin.name == "demo" && plugin.marketplace == "mk" && plugin.author == "ygw")
        #expect(plugin.skillCount == 2 && plugin.agentCount == 1 && plugin.mcpServerNames == ["m1"])
        #expect(!plugin.isEnabled)
        #expect(store.enabledRoots().isEmpty)

        try SettingsStore(paths: box.paths).set(["enabledPlugins", "demo@mk"], to: true, in: .user)
        plugin = try #require(store.installed().first)
        #expect(plugin.isEnabled)
        #expect(store.enabledRoots()["demo"]?.path == install.path)
        #expect(store.marketplaces().first?.source == "a/b")
    }

    @Test("CLI 参数构造与输入校验")
    func arguments() throws {
        #expect(PluginStore.installArguments("a@b", scope: "user") == ["plugin", "install", "a@b", "--scope", "user"])
        #expect(PluginStore.toggleArguments("a", enable: false, scope: "project") == ["plugin", "disable", "a", "--scope", "project"])
        #expect(PluginStore.marketplaceUpdateArguments(nil) == ["plugin", "marketplace", "update"])
        try PluginStore.validateArgument("owner/repo")
        #expect(throws: ConfigError.self) { try PluginStore.validateArgument("--help") }
        #expect(throws: ConfigError.self) { try PluginStore.validateArgument("  ") }
    }
}

@Suite("CLI 执行器")
struct CLIRunnerTests {
    @Test("收集输出与退出码,超时会被终止,缺失的可执行文件报错")
    func runner() async {
        let ok = await CLIRunner(executable: "/bin/echo").run(["hello"])
        #expect(ok.succeeded && ok.standardOutput.contains("hello"))
        let fail = await CLIRunner(executable: "/bin/sh").run(["-c", "echo oops >&2; exit 3"])
        #expect(fail.exitCode == 3 && fail.failureMessage.contains("oops"))
        let slow = await CLIRunner(executable: "/bin/sleep").run(["30"], timeout: 0.5)
        #expect(slow.timedOut && !slow.succeeded)
        let missing = await CLIRunner(executable: "/nonexistent/bin").run([])
        #expect(missing.exitCode == -1)
    }
}

@Suite("监听与配置中心")
struct WatcherCenterTests {
    @Test("路径过滤:只关心 Claude 配置相关文件")
    func relevance() {
        let claude = "/h/.claude", ws = "/w"
        #expect(ConfigWatcher.isRelevant("/h/.claude/settings.json", claudeDirectory: claude, workspace: ws))
        #expect(ConfigWatcher.isRelevant("/h/.claude/skills/a/SKILL.md", claudeDirectory: claude, workspace: ws))
        #expect(!ConfigWatcher.isRelevant("/h/.claude/history.jsonl", claudeDirectory: claude, workspace: ws))
        #expect(!ConfigWatcher.isRelevant("/h/.claude/plugins/cache/x/y", claudeDirectory: claude, workspace: ws))
        #expect(ConfigWatcher.isRelevant("/w/.mcp.json", claudeDirectory: claude, workspace: ws))
        #expect(ConfigWatcher.isRelevant("/w/.claude/agents/a.md", claudeDirectory: claude, workspace: ws))
        #expect(!ConfigWatcher.isRelevant("/w/src/main.swift", claudeDirectory: claude, workspace: ws))
    }

    @Test("文件变化触发回调(去抖后)")
    func watching() async throws {
        let box = try Sandbox(); defer { box.cleanup() }
        try FileManager.default.createDirectory(at: box.home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        let counter = Counter()
        let watcher = ConfigWatcher(paths: box.paths, debounce: 0.1) { counter.increment() }
        watcher.start()
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(400))
        try box.write("{}", to: ".claude/settings.json", base: box.home)
        for _ in 0..<50 where counter.value == 0 { try await Task.sleep(for: .milliseconds(100)) }
        #expect(counter.value >= 1)
        // 工作区里的无关文件不触发
        let before = counter.value
        try box.write("x", to: "src/a.swift", base: box.workspace)
        try await Task.sleep(for: .milliseconds(700))
        #expect(counter.value == before)
    }

    @Test("配置中心聚合快照;损坏的区块只影响自己")
    @MainActor
    func center() async throws {
        let box = try Sandbox(); defer { box.cleanup() }
        try box.write(#"{"mcpServers":{"a":{"command":"x"}}}"#, to: ".claude.json", base: box.home)
        try box.write("{ broken", to: ".claude/settings.json", base: box.home)
        try box.write("# m", to: "CLAUDE.md", base: box.workspace)
        let snapshot = ConfigCenter.load(paths: box.paths)
        #expect(snapshot.mcp.count == 1)
        #expect(snapshot.errors["Hooks"] != nil)
        #expect(snapshot.memory.contains { $0.kind == .project && $0.exists })

        let center = ConfigCenter(paths: box.paths)
        let ok = center.perform("已保存") { try MCPStore(paths: box.paths).save(MCPServerConfig(name: "b", command: "y"), scope: .user) }
        #expect(ok)
        for _ in 0..<50 where center.snapshot.mcp.count < 2 { try await Task.sleep(for: .milliseconds(50)) }
        #expect(center.snapshot.mcp.count == 2)
        #expect(!center.perform { try MCPStore(paths: box.paths).remove(name: "nope", scope: .user) })
        #expect(center.lastError != nil)
    }
}

/// 线程安全计数器。
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
