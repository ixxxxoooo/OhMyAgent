# OhMyAgent 项目 Agent 规范

> @author ygw
> 本文件是后续所有 Agent(Cursor、Claude Code 等)在本仓库工作的唯一规范。冲突时以本文件为准;
> 用户级全局规则中与 Java 相关的条目(`ApiLog`、`ObjectUtils` 等)**不适用于本项目**。

## 1. 项目概览

macOS 27 专用、100% 原生(Swift 6 + SwiftUI + AppKit,无 WebView)的 Cursor 风格 Agent 工作台,通过 ACP(stdio JSON-RPC)接管本机已安装的 Claude Code。
不做账号登录 UI:直接使用本机 `claude` 自带的凭据。

### 模块地图(`Sources/`)
- `ACPKit`:JSON-RPC、ACP v1 模型、连接 actor、脚本化 Agent(测试用)。
- `AgentHost`:子进程、工具链定位、Agent 注册表、Bridge。
- `ChatKit`:会话模型(含运行中引导/排队/图片/目标)、时间线、补全(来源徽标、@子 Agent)、客户端斜杠命令(`LocalCommands`)、Markdown 解析、更新检查、AttentionCenter(运行/未读状态)、RecentStore(无视图)。
- `WorkbenchKit`:工作台模型(多项目、项目→会话树、布局与状态持久化,无视图)。
- `ClaudeConfigKit`:读写 `~/.claude`、`.mcp.json` 等配置。
- `DiffKit` / `EditorKit`:Diff 与编辑器。
- `GitKit`:`git` 命令的类型化封装与输出解析(状态、暂存、提交、分支、历史、blame、stash、冲突;无 UI)。
- `LSPKit`:LSP 客户端(Content-Length 分帧、`LSPClient` actor、服务器定位、`LSPManager` 懒启动/复用/空闲回收;复用 ACPKit 的 JSON-RPC 连接,无视图)。
- `MermaidKit`:Mermaid 原生渲染(纯 Swift):解析 → 分层布局 → 场景(`MScene`)→ SwiftUI Canvas/PNG;支持 flowchart/graph、sequenceDiagram、stateDiagram-v2、classDiagram、pie、gantt。
- `IconKit`:Lucide 图标(生成数据 + SVG path 解析 + `Image.om`);界面禁止再用 SF Symbol(`Scripts/gen-icons.py` 重新生成)。
- `DesignSystem`:设计令牌与玻璃材质。
- `OhMyAgentApp`:应用本体(SwiftUI/AppKit 视图)。
- `FakeAgent` / `OhMyAgentBridge`:辅助可执行文件。
- 新增模块请登记在本节与「开发进度.md」的代码索引中。

## 2. 常用命令
- 构建并组装应用:`Scripts/bundle.sh [debug|release]`
- 重启应用(结束旧进程 → 构建 → 启动):`Scripts/restart.sh`(`OMA_AGENT=fake` 使用脚本化 Agent)
- 本地 CI(零警告构建 + 全部测试):`Scripts/ci.sh`
- 性能门槛:`Scripts/perf.sh`;发布:`Scripts/release.sh`
- 日志:`Scripts/logs.sh`(P1 之后可用)
- 启用推送前 CI:`git config core.hooksPath .githooks`(已在本仓库启用)

## 3. 开发流程(必须遵守)
1. 开发前先读「开发进度.md」,优先复用现有代码,避免重复造轮子。
2. 改完代码 → `Scripts/ci.sh`(必须零警告、测试全绿)→ `Scripts/restart.sh` 重启应用验证改动真实生效。
3. **每完成一个功能点就提交一次**:一次提交只包含一个功能或修复,不要把多个功能混在一起;
   提交信息使用**中文 Conventional Commits**(`feat: …`、`fix: …`、`refactor: …`、`test: …`、`docs: …`、`chore: …`)。
4. **每次提交后立即 `git push`** 到远端 `origin/main`(`origin` = https://github.com/ixxxxoooo/OhMyAgent.git)。
5. 功能完成后更新「开发进度.md」(里程碑状态、代码索引、偏差说明)。
6. 禁止提交:`build/`、`dist/`、`.build/`、`Vendor/acp/node_modules/`、日志文件、任何密钥或令牌。
7. 文档放 `.specstory/history/docs/yyyyMMdd_功能名称.md`;SQL 放 `.specstory/history/sql/`。

## 4. Swift 最佳实践
- Swift 6 严格并发,零警告(`-warnings-as-errors`)。UI 与视图模型标注 `@MainActor`;共享可变状态用 `actor` 隔离;跨并发边界的类型必须 `Sendable`。
- 状态管理用 `@Observable`(Observation),视图保持小而纯;大视图拆分为子视图;避免在 `body` 内做耗时计算或 I/O。
- 值类型(`struct`/`enum`)优先;类仅用于需要引用语义或身份的场景;访问控制取最小(默认 `internal`,`private` 优先)。
- 禁止强制解包(`!`)、`try!`、`as!`、`fatalError` 处理可恢复错误;空值判断使用 `isEmpty`/可选绑定;错误使用明确的 `Error` 类型并向上传递或记录。
- 异步用 `async/await` 与结构化并发(`Task`、`TaskGroup`),避免回调嵌套与 `DispatchQueue` 手写同步(系统 API 桥接除外)。
- 主线程不得做磁盘/网络/子进程阻塞操作;热路径(流式渲染、滚动、输入)避免不必要的分配与视图重建。
- 方法 ≤ 300 行;命名:类型 UpperCamelCase,方法/变量 lowerCamelCase,常量不使用全大写下划线风格(遵循 Swift API 设计准则)。
- 注释一律中文;每个类型与方法写文档注释(用途、参数、返回值);文件头含 `@author ygw`。
- 对外接口入参做合法性校验。
- 测试使用 Swift Testing(`@Test`/`#expect`),新功能必须带测试;测试不得依赖真实模型或网络。
- 本地化:界面文案用字面量(中文为开发语言)并同步 `Resources/en.lproj/Localizable.strings`;以 `String` 传入的文案用 `String(localized:)`。
- 无障碍:仅图标的控件必须有 `accessibilityLabel`;动画经 `omWithAnimation` 以遵循「减弱动态效果」。

## 5. 日志规范(P1 起强制)
- 只使用 `OMLog`(`Log.<category>.info/debug/warning/error`),禁止 `print`/`NSLog`。
- 日志文件:`~/Library/Logs/OhMyAgent/`;排查问题先看这里。
- 日志需包含关联标识(sessionId / requestId / toolCallId)与耗时;每个 `catch` 必须记录上下文。
- 严禁记录令牌、`ANTHROPIC_*`、`Authorization`、完整环境变量;协议载荷默认不记录,需经脱敏器。

## 6. UI 验证约定(不抢焦点)
- 启动:`open -g -n build/OhMyAgent.app --env OMA_AGENT=fake --env OMA_PROJECT_ROOT=$PWD`。
- 调试钩子:`OMA_DRAFT`、`OMA_OPEN_SETTINGS`、`OMA_SETTINGS_PAGE`、`OMA_AGENT=fake|direct`、`OMA_LSP_PROBE=行:列`、`OMA_AUTOALLOW`(自动批准权限)、`OMA_PERF_OUT`。
- 截图用 `screencapture -x -o -l<windowId>`;禁止用 osascript 发送按键;验证后删除截图。
- 每次改动后重启应用与适配器子进程,确认修改在运行时真实生效。

## 7. 安全
- 不读取 Keychain 中的 OAuth 令牌;官方 `claude` 使用自己的凭据。
- Developer ID 分发,非沙盒;签名与公证脚本见 `Scripts/release.sh`。
