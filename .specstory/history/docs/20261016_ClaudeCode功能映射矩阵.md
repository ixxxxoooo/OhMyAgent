# Claude Code 功能映射矩阵

> @author ixxxxoooo
> 通道说明:
> - **A**:ACP 原生(经适配器)
> - **B**:配置文件层(直接读写 `~/.claude/settings.json`、`~/.claude.json`、`.mcp.json`、`.claude/*`、`CLAUDE.md`)
> - **C**:CLI 子进程(`claude mcp|plugin|auth|doctor` 等)
> - **D**:客户端自实现
> - **N/A**:TUI 专属,GUI 以等价方式替代或不适用,并说明原因

## 1. 核心对话能力

| Claude Code 能力 | 通道 | GUI 实现 |
| --- | --- | --- |
| Extended Thinking | A | `agent_thought_chunk` → 可折叠思维面板 |
| 文本流式 | A | `agent_message_chunk` → 零延迟渐显 + 高亮 |
| 工具调用 | A | `tool_call` / `tool_call_update` → 工具卡片 |
| 权限审批 | A | `session/request_permission` → 原生审批面板 |
| 计划/Todo | A | `plan` 更新 → Plan 面板 |
| Subagent | A | 嵌套会话,可单独取消 |
| 后台终端 | A+D | ACP terminal 能力 + 自实现终端视图 |
| Elicitation | A | 结构化表单 / URL 跳转 |
| 图片/@ 提及 | A | 输入区粘贴、拖入、补全 |
| 取消 | A | `session/cancel`(Esc / 停止按钮) |
| 会话恢复 | A | `session/load` / `resume` / `list` / `delete` / `close` |
| 用量与费用 | A | session usage 更新 → 用量环 |

## 2. 斜杠命令全量映射

### 2.1 会话类

| 命令 | 通道 | GUI 入口 |
| --- | --- | --- |
| `/clear` | A | 新建会话(菜单、⌘N) |
| `/compact [instructions]` | A | 上下文用量环菜单 → 压缩,压缩事件在时间线可视化 |
| `/resume [session]` | A | 会话列表双击 / ⌘P |
| `/fork [prompt]` | A | 会话菜单 → 分叉 |
| `/rewind` | D | 检查点时间线 → 回滚文件与会话 |
| `/rename [name]` | A | 会话标题双击编辑 |
| `/export [filename]` | D | 会话菜单 → 导出 Markdown |
| `/recap` | A | 以斜杠命令透传,结果以卡片展示 |
| `/branch [name]` | C | Git 面板 → 新建分支 |
| `/copy [N]` | D | 消息右键 → 复制 |
| `/btw [question]` | A | 旁路提问浮层 |
| `/exit` | N/A | 关闭窗口(⌘W) |

### 2.2 上下文与成本

| 命令 | 通道 | GUI 入口 |
| --- | --- | --- |
| `/context [all]` | A | 上下文用量环详情 |
| `/cost` | A | 用量与成本面板 |
| `/usage` `/usage-credits` | C | 设置 → 用量与成本 |
| `/stats` `/insights` | C | 设置 → 用量与成本 |
| `/status` | C | 状态栏 + 设置 → 诊断 |
| `/heapdump` | N/A | 诊断页导出诊断包代替 |

### 2.3 配置类

| 命令 | 通道 | GUI 入口 |
| --- | --- | --- |
| `/config [key=value]` | B | 设置窗口 |
| `/model [model]` | A | 工具栏模型选择器(config option) |
| `/effort [level]` | A | 工具栏思考强度选择器 |
| `/fast [on\|off]` | A | 工具栏 fast 开关 |
| `/permissions` | B | 设置 → 权限 |
| `/memory` | B | 设置 → 记忆与指令 |
| `/output-style [style]` | B | 设置 → Agent 与模型 |
| `/advisor` `/autocompact` | A/B | 设置 → Agent 与模型 |
| `/theme` `/color` `/tui` `/vim` `/scroll-speed` `/focus` | N/A | TUI 外观,由 GUI 外观设置替代 |
| `/keybindings` | D | 设置 → 快捷键(GUI 快捷键体系独立) |
| `/statusline` | B | 底部状态栏,支持自定义脚本 |
| `/privacy-settings` | C | 设置 → 隐私 |
| `/terminal-setup` `/radio` `/voice` `/stickers` `/powerup` | N/A | 终端/娱乐/语音专属功能 |

### 2.4 扩展类

| 命令 | 通道 | GUI 入口 |
| --- | --- | --- |
| `/mcp [reconnect\|enable\|disable]` | A+B+C | 设置 → MCP |
| `/skills` `/reload-skills` `/skill-doctor` | B | 设置 → Skills |
| `/plugin` `/reload-plugins` `/plugin-authoring` | C | 设置 → Plugins |
| `/agents` `/list-agents` | B | 设置 → Subagents |
| `/hooks` | B | 设置 → Hooks |
| `/add-dir` | A | 会话设置 → 附加目录(additionalDirectories) |
| `/update-config` | B | 设置窗口 |

### 2.5 工程类

| 命令 | 通道 | GUI 入口 |
| --- | --- | --- |
| `/init` | A | 项目欢迎页按钮 |
| `/review` `/code-review` `/ultrareview` | A | 透传 + 结果卡片 |
| `/security-review` | A | 透传 + 结果卡片 |
| `/diff` | D | Diff 面板 |
| `/pr-comments` `/autofix-pr` | A | 透传 |
| `/doctor` | C | 设置 → 诊断 |
| `/sandbox` | B | 设置 → 权限 → 沙盒 |
| `/debug` `/verify` `/simplify` `/batch` `/run` `/run-skill-generator` | A | 内置 skill,透传 |
| `/claude-api` `/dataviz` `/deep-research` `/design*` `/slides` | A | 内置 skill,透传 |

### 2.6 编排类

| 命令 | 通道 | GUI 入口 |
| --- | --- | --- |
| `/plan [description]` | A | 模式选择器切到 plan |
| `/goal` | A | 目标条(goal 扩展) |
| `/loop` `/schedule` | A+D | 定时任务面板 |
| `/background` `/tasks` `/stop` `/subtask` | A | 后台任务面板 |
| `/workflows` `/workflow-authoring` `/ultraplan` | A | 透传 |
| `/cd` | A | 切换会话 cwd(新建会话) |

### 2.7 账号与外部集成

| 命令 | 通道 | GUI 入口 |
| --- | --- | --- |
| `/login` `/logout` | C+A | 设置 → 账号与鉴权(`claude auth`、ACP authenticate) |
| `/upgrade` `/passes` `/rate-limit-options` | C | 跳转网页 |
| `/chrome` `/claude-in-chrome` | N/A | 浏览器扩展联动,仅提示 |
| `/desktop` `/mobile` `/remote-control` `/remote-env` `/teleport` `/web-setup` | N/A | 跨端交接,仅提供状态展示与说明 |
| `/install-github-app` `/install-slack-app` | C | 设置 → 集成,启动 CLI 流程 |
| `/ide` | N/A | 本应用自身即宿主 |
| `/feedback` `/bug` `/help` `/release-notes` `/team-onboarding` `/artifacts*` `/design-sync` `/auto-mode-setup` `/fewer-permission-prompts` | A/C | 帮助菜单或透传 |

## 3. 配置文件与目录

| 对象 | 路径 | 通道 |
| --- | --- | --- |
| 用户设置 | `~/.claude/settings.json` | B |
| 项目设置 | `.claude/settings.json`、`.claude/settings.local.json` | B |
| 托管设置 | 系统托管目录 | B(只读) |
| MCP local/user | `~/.claude.json` | B/C |
| MCP project | `.mcp.json` | B |
| Skills | `~/.claude/skills/*/SKILL.md`、`.claude/skills/*/SKILL.md` | B |
| 旧 commands | `.claude/commands/*.md` | B(视为 Skill) |
| Subagents | `.claude/agents/*.md`、`~/.claude/agents` | B |
| Rules | `.claude/rules/*.md` | B |
| 记忆 | `CLAUDE.md`、`AGENTS.md`、auto memory | B |
| Hooks | settings 中 `hooks` 字段 | B |
| Plugins | `~/.claude/plugins` | C(只读展示 + CLI 操作) |

## 4. 权限模式

| 模式 | 说明 | GUI 处理 |
| --- | --- | --- |
| default | 敏感操作询问 | 默认 |
| acceptEdits | 自动接受文件编辑与常见文件系统命令 | 一键切换 |
| plan | 只规划不执行 | 一键切换 |
| auto | 分类器自动判断 | 设置中启用,需用户级配置 |
| dontAsk | 未预批准的一律拒绝 | 设置中启用 |
| bypassPermissions | 全部放行 | 二次确认,可被托管策略禁用,仅在隔离环境提示 |

## 5. Hook 事件(GUI 只读展示 + 可视化编辑)

SessionStart、UserPromptSubmit、PreToolUse、PermissionRequest、PostToolUse、PostToolUseFailure、Notification、SubagentStart、SubagentStop、Stop、PreCompact、PostCompact、InstructionsLoaded、ConfigChange、CwdChanged、FileChanged、WorktreeCreate、WorktreeRemove、Elicitation、SessionEnd 等。具体事件集以 Claude Code 当前版本文档为准,编辑器的事件列表由 `ClaudeConfigKit` 内置枚举并支持未知事件透传。
