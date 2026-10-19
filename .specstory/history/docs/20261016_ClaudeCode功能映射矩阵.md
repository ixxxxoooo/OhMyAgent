# Claude Code 功能映射矩阵(含 MCP / 技能扩展支持)

> @author ixxxxoooo
> 本文合并了原《MCP与技能扩展支持》。状态以 `Sources/` 代码为准(2026-10-19 核对),找不到对应实现的条目一律标「未实现」。
> **通道**:A = ACP 原生(经适配器);B = 直接读写配置文件(`ClaudeConfigKit`);C = 调用 `claude` CLI(`CLIRunner`);D = 客户端自实现;N/A = TUI 专属或不适用。
> **状态**:已实现 / 部分 / 未实现 / 不适用。

## 1. 核心对话能力

| 能力 | 通道 | 状态 | GUI 实现 |
| --- | --- | --- | --- |
| 思维流 `agent_thought_chunk` | A | 已实现 | 时间线思维块 |
| 文本流式 | A | 已实现 | `MarkdownTextRunRenderer` 增量渲染 |
| 工具调用 | A | 已实现 | 工具行/卡片(`ToolRowViews`、`ToolPresentation`) |
| 权限审批 | A | 已实现 | 审批卡(`ToolApprovalCard`),`OMA_AUTOALLOW` 可自动批准 |
| 计划/Todo | A | 已实现 | Plan 卡与 `*.plan.md` 标签页(`PlanDocument`) |
| 子 Agent | A | 已实现 | 子代理卡片(`SubagentCardView`、`SubagentStatus`) |
| 后台终端 | A+D | 已实现 | `TerminalManager`(ACP terminal 能力)+ 终端面板 |
| Elicitation / AskUserQuestion | A | 已实现 | `Elicitation`、问题向导(`QuestionWizardView`) |
| 图片 / `@` 提及 | A | 已实现 | `ImageIntake`、`FileMentions`、`Completion` |
| 取消 | A | 已实现 | `session/cancel` |
| 会话恢复 | A | 已实现 | `session/load` / `resume` / `list` / `close`(`ACPClient`) |
| 用量与上下文 | A | 已实现 | `ContextUsage`、`ContextUsagePanel`、`PlanUsage` |
| 运行中引导/排队 | D | 已实现 | `followUps` / `queuedPrompt` |

## 2. 斜杠命令

客户端本地命令见 `ChatKit/LocalCommands.swift`;Claude Code 内置命令清单见 `ChatKit/ClaudeBuiltinCommands.swift`;其余命令来自 Agent 的 `available_commands_update`,以补全项透传给 Agent。

| 命令 | 状态 | GUI 入口 |
| --- | --- | --- |
| `/new` `/clear` | 已实现 | 新对话 |
| `/help` `/status` | 已实现 | 客户端本地展示 |
| `/model` | 已实现 | 无参数打开模型菜单,带参数切换 |
| `/config` `/permissions` `/doctor` `/usage` `/cost` | 已实现 | 分别打开对应设置页 |
| `/agents` `/skills` `/memory` `/hooks` `/plugin` `/mcp` | 已实现 | 打开工具与扩展对应页;`/mcp` 带参数时交给 Agent |
| `/resume` | 已实现 | 打开历史会话 |
| `/rename` | 已实现 | 重命名当前会话 |
| `/export` | 已实现 | 导出 Markdown |
| `/explore` `/worktree` `/apply-worktree` `/delete-worktree` `/best-of-n` | 已实现(客户端扩展) | Explore 子 Agent、Git 工作树、多模型对比 |
| `/compact` `/init` `/review` `/security-review` `/context` `/output-style` `/effort` `/autocompact` | 部分 | 在 Claude Code 内置清单里,作为命令透传给 Agent,无专属 GUI |
| `/login` `/logout` | 部分 | 在内置清单里,凭据由本机 `claude` 管理,应用不做登录 UI |
| `/goal` | 已实现 | 输入区上方目标条(`ChatStatusViews`) |
| fork 会话 | 已实现 | `SessionModel.forkCurrentSession`(`session/fork`) |
| `/rewind` | 不适用(有等价功能) | 回复「依赖终端界面」,用每轮结束的「本轮改动」卡片回退到检查点(`CheckpointStore`) |
| `/add-dir` | 不适用(有等价功能) | 提示改用工作区「添加文件夹…」(`WorkspaceFolders`) |
| `/todos` | 不适用(有等价功能) | 待办显示在输入框上方的待办卡片 |
| `/vim` `/terminal-setup` `/statusline` `/ide` `/install-github-app` `/bug` `/release-notes` `/pr-comments` | 不适用 | 以提示文案说明不可用或已移除 |
| `/loop` `/schedule` | 部分 | 客户端有独立的自动化(`AutomationKit`:定时与 cron 子集),与同名斜杠命令不是同一实现 |
| `/btw` `/recap` `/reload-skills` | 未实现 | 无专属入口 |

## 3. 配置文件与扩展对象

| 对象 | 路径 | 通道 | 状态 / GUI |
| --- | --- | --- | --- |
| 用户/项目/本地设置 | `~/.claude/settings.json`、`.claude/settings.json`、`.claude/settings.local.json` | B | 已实现;`ConfigScope` 为 user / project / local |
| 托管设置 | 系统托管目录 | B | 未实现(`ConfigScope` 无 managed 作用域) |
| MCP | `~/.claude.json`、`.mcp.json` | B+C | 已实现(`MCPStore`、设置 → MCP) |
| Skills | `~/.claude/skills`、`.claude/skills`、旧 `commands` | B | 已实现(`SkillStore`、设置 → 技能、新建向导 `CommandCreateSheet`) |
| Subagents | `~/.claude/agents`、`.claude/agents` | B | 已实现(设置 → 子 Agent) |
| 记忆/规则 | `CLAUDE.md`、`AGENTS.md`、rules | B | 已实现(`MemoryStore`、设置 → 规则) |
| Hooks | settings 的 `hooks` | B | 已实现(`HooksStore`、设置 → Hooks) |
| Plugins | `~/.claude/plugins` | B 只读 + C 操作 | 已实现(`PluginStore`:安装/卸载/启停/更新/市场增删与更新走 `claude plugin`) |
| 项目信任 | - | B | 已实现(`ProjectTrust`、设置 → 项目信任) |

## 4. MCP

- 传输:`MCPStore` 支持 stdio / http / sse / ws,SSE 在界面标注「已弃用」。
- 作用域:user / project / local(`ConfigScope`);插件、claude.ai 连接器、managed 作用域未实现。
- 状态:connected / needsAuth(界面显示「需要认证」)/ failed / unknown(由 `claude mcp list` 输出解析);项目 `.mcp.json` 服务器的审批状态(`needsApproval`,依据 `enabledMcpjsonServers` / `disabledMcpjsonServers` 等设置)会在列表中体现。
- 管理页(`MCPManagerView`)支持:添加(表单与 JSON,等价 `add-json`)、编辑、删除、启停、重连、从 Claude Desktop 配置导入(读取 `claude_desktop_config.json`)。
- 运行参数:`MCP_TIMEOUT`、`MAX_MCP_OUTPUT_TOKENS` 等环境变量在设置 → 高级;MCP 按需加载见 `McpToolSearch`。
- 输入框补全:MCP 提供的 prompt 以 `/mcp__服务器__提示` 出现在斜杠补全里。
- 会话 MCP 注入:`session/new` 的 `mcpServers` 由 `SessionModel` 组装(Bridge 以及注册表里启用的 `AgentMCPEntry`);用户自己的 MCP 由 `claude` 自行加载。
- 未实现:Channels 展示、MCP resources 的 `@` 补全(Sources 中未找到对应代码)。

## 5. Skills / Subagents / Hooks / Memory

- Skills:`SkillStore` 解析 frontmatter(含 `disable-model-invocation`),设置页可视化编辑、新建;未知字段保留。
- Hooks:事件清单取自 `HooksStore.events`(SessionStart、SessionEnd、UserPromptSubmit、PreToolUse、PermissionRequest、PostToolUse、PostToolUseFailure、Notification、SubagentStart、SubagentStop、Stop、StopFailure、PreCompact、PostCompact、InstructionsLoaded、TeammateIdle);处理器类型 command / http / prompt / agent / mcp_tool;来自插件的 Hook 只读。
- Memory:多层 `CLAUDE.md` / rules 编辑;未实现「本会话实际加载了哪些指令文件」视图。

## 6. OhMyAgent Bridge 工具

Bridge 是挂在 `LocalGateway` 上的进程内 HTTP MCP 服务(`Sources/AgentHost/BridgeServer.swift`,MCP 服务名 `ohmyagent`),工具名即 `BridgeTool` 的 rawValue,不带前缀:

| 类别 | 工具名 |
| --- | --- |
| 编辑器 | `open_file`、`show_diff`、`get_selection` |
| 通知 | `notify` |
| 画布 | `canvas_create`、`canvas_update`、`canvas_list` |
| 搜索 | `search_code` |
| 浏览器 | `browser_navigate`、`browser_snapshot`、`browser_click`、`browser_hover`、`browser_back`、`browser_forward`、`browser_reload`、`browser_type`、`browser_scroll`、`browser_screenshot`、`browser_console`、`browser_network`、`browser_tabs` |
| 交互 | `ask_user_question` |
| 图表 | `chart_guide` |

`browser_screenshot` 可返回 image 内容块。Bridge 默认启用全部工具(`enabled` 可裁剪)。

## 7. 权限模式

模式选择器的色调映射在 `ModeTone`(含 default、plan 等);模式列表来自 Agent 上报的 config option / `current_mode_update`。设置 → 权限(`AgentPermissionPages`)提供权限规则编辑,选择「不经确认」类模式时会显示风险警告文案。

## 8. 其他对象

| 对象 | 状态 |
| --- | --- |
| 检查点/回退 | 已实现(`DiffKit/CheckpointStore`) |
| 沙盒 | 终端沙箱 `TerminalSandbox` 已实现(客户端终端);Claude Code 自身 sandbox 配置页未在 Sources 中找到,视为未实现 |
| 定时任务 | 客户端自动化 `AutomationKit` 已实现 |
| Quick Ask 全局热键条 | 未实现(Sources 中无对应代码) |
| Statusline 自定义脚本 | 不适用 |
