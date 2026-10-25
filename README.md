# OhMyAgent

macOS 原生的 Cursor 风格 Agent 工作台:通过 ACP(stdio JSON-RPC)接管本机已安装的 Claude Code,在一个窗口里完成对话、改代码、看 Diff、跑终端和提交 Git。

- **100% 原生**:Swift 6 + SwiftUI + AppKit,仅内置浏览器标签页使用 `WKWebView`;不依赖 Node。
- **不做账号登录**:直接使用本机 `claude` 自带的凭据,OhMyAgent 不读取 Keychain 里的 OAuth 令牌。
- **仅支持 macOS 27**。

> 作者:ixxxxoooo

## 功能

- **会话工作台**:多项目、会话树、多标签与分屏停靠;流式 Markdown、代码高亮、Mermaid、表格、工具卡与子 Agent 嵌套展示;跨代码块/表格/输出的连续文本选择。
- **Agent 能力**:斜杠命令与 `@` 文件补全、计划卡与待办、权限与提问卡片、检查点回退、图片输入、运行中引导/排队、历史会话恢复与分叉。
- **编辑与代码**:原生 rope 引擎编辑器(语法高亮、tree-sitter、LSP、Markdown 阅读)、Diff(统一/并排、词级)、文件树、全局搜索与 ⌘K 中央搜索。
- **Git**:状态、历史、blame、提交图谱、分支切换、拉取/推送、stash、冲突解决。
- **终端**:真实 PTY 终端(SwiftTerm),按标签常驻。
- **IDE 模式**:独立的 IDE 窗口与 Agent 窗口,可在融合模式下一键切换。
- **模型与提供商**:本机回环网关代理,支持 Anthropic 透传与 OpenAI 协议转换;真实密钥只存在于代理内存。
- **主题**:默认「Cursor 纸感」,另有深色与多套主题包,可自定义主题;中英双语界面。

## 环境要求

- macOS 27、Xcode(Swift 6.4 工具链)
- 本机已安装并登录 [Claude Code](https://docs.claude.com/en/docs/claude-code)(`claude` 命令可用)

## 快速开始

```bash
git clone https://github.com/ixxxxoooo/OhMyAgent.git
cd OhMyAgent
Scripts/make-signing-cert.sh   # 一次性:创建本地自签证书,避免重编译后系统权限失效
Scripts/restart.sh             # 构建并启动开发版(build/OhMyAgent Dev.app)
```

开发版与稳定版数据完全隔离(Bundle ID `com.ixxxxoooo.OhMyAgent.dev`),开发版首次启动会从稳定版复制一次数据与偏好。

## 常用命令

| 目的 | 命令 |
| --- | --- |
| 构建并组装应用 | `Scripts/bundle.sh [debug\|release\|dev]` |
| 重启开发版 | `Scripts/restart.sh`(`OMA_AGENT=fake` 使用脚本化 Agent) |
| 更新稳定版 | 在系统 Terminal.app 运行 `Scripts/promote.sh` |
| 演示模式(隔离沙盒 + 脚本化 Agent) | `Scripts/demo.sh [--reset] [--scenario <名>]` |
| 单元测试 | `Scripts/test.sh`(勿长期直接用 `swift test`) |
| 本地 CI(本地化、UI 规范、零警告构建、全部测试) | `Scripts/ci.sh` |
| 性能门槛 | `Scripts/perf.sh` |
| 查看日志 | `Scripts/logs.sh tail\|grep\|last\|report` |
| 打包发布(本地) | `Scripts/release.sh` |
| 发布到 GitHub Release | `Scripts/publish.sh`(会打 tag 并创建 Release) |

日志位于 `~/Library/Logs/OhMyAgent[-Dev]/`,数据位于 `~/Library/Application Support/OhMyAgent[-Dev]/`。

## 项目结构

```
Sources/
├── ACPKit            JSON-RPC、ACP v1 模型、连接 actor、脚本化 Agent 与演示场景
├── AgentHost         子进程、工具链定位、Agent 注册表、进程内 MCP Bridge、终端沙箱
├── ClaudeAgentKit    Claude Code 原生 ACP 适配器(纯 Swift,驱动 claude stream-json)
├── ChatKit           会话模型、时间线、补全、Markdown、提供商与模型映射
├── WorkbenchKit      多项目、会话树、布局与持久化、停靠、搜索索引、工作树
├── EditorCore        原生编辑器内核:文本绳、撤销栈、共享文档、选区/折叠/换行
├── EditorKit         高亮、tree-sitter、Markdown 就地渲染
├── GitKit / DiffKit / LSPKit / MermaidKit / SpreadsheetKit / CanvasKit
├── ProviderProxyKit  本机回环网关与模型代理
├── ClaudeConfigKit   ~/.claude 与 .mcp.json 的读写与监听
├── IconKit           Lucide 图标、文件类型图标、品牌图标
├── DesignSystem      设计令牌、主题包、玻璃材质
├── IDEKit            IDE 模式模型
├── OMLog             日志与 AppEnv 路径隔离
└── OhMyAgentApp      应用本体(SwiftUI / AppKit 视图)
```

每个模块的完整说明见 [`.specstory/history/docs/20261023_模块地图.md`](.specstory/history/docs/20261023_模块地图.md)。

## 开发规范

- 本仓库的唯一规范是 [`AGENTS.md`](AGENTS.md):Swift 6 严格并发、零警告、UI 令牌(`OMColors`/`OMFonts`/`OMRadius`)、本地化、日志与提交流程。
- 开发前先读 [`开发进度.md`](开发进度.md),优先复用现有代码;功能完成后更新它。
- 每个功能点或修复单独提交,提交信息使用中文 Conventional Commits(`feat:`、`fix:`、`refactor:`、`test:`、`docs:`、`chore:`),提交后立即推送。
- 新增界面文案必须同步 `Resources/en.lproj/Localizable.strings`;`Scripts/ci.sh` 会扫描遗漏。
- 重构规格文档集(功能、交互与 UI 布局的实现级说明)入口:`.specstory/history/docs/20261024_重构规格_00_总览与索引.md`。

## 发布

1. 修改 `Resources/Info.plist` 的 `CFBundleShortVersionString` 并提交推送。
2. 运行 `Scripts/publish.sh`:release 构建、签名、生成 dmg/zip 与 `appcast.json`,打 tag 并创建 GitHub Release。应用内「检查更新」读取最新 Release 的 `appcast.json`。
3. 默认使用本机自签证书且不公证,仅适合自用;面向他人分发请设置 `DEVELOPER_ID` 与 `NOTARY_PROFILE`(见 `Scripts/release.sh` 头部说明)。
4. `OMA_NOTES` 可手动指定更新说明(分号分隔多条);默认取上一个 tag 以来的提交标题,标题中含反斜杠时会破坏 appcast JSON,建议手动指定。

## 致谢与许可

图标与第三方资源的许可文本见 [`Resources/Licenses`](Resources/Licenses)(Lucide、Material Icon Theme、Lobe Icons)。终端使用 [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)。

仓库尚未声明开源许可证,默认保留所有权利。
