# OhMyAgent 项目 Agent 规范

> @author ixxxxoooo
> 本文件是后续所有 Agent(Cursor、Claude Code 等)在本仓库工作的唯一规范。冲突时以本文件为准;
> 用户级全局规则中与 Java 相关的条目(`ApiLog`、`ObjectUtils` 等)**不适用于本项目**。

## 1. 项目概览

macOS 27 专用、100% 原生(Swift 6 + SwiftUI + AppKit;**唯一例外**:内置浏览器标签页用 `WKWebView`,其余界面一律原生)的 Cursor 风格 Agent 工作台,通过 ACP(stdio JSON-RPC)接管本机已安装的 Claude Code。
不做账号登录 UI:直接使用本机 `claude` 自带的凭据。

### 模块索引(`Sources/`)
本节只列一行索引;**每个模块的完整说明见 `.specstory/history/docs/20261023_模块地图.md`,改动某模块前先读对应条目**(本文件每个请求都会发给模型,不要再把细节写回这里)。
- `ACPKit`:JSON-RPC、ACP v1 模型、连接 actor;脚本化 Agent、场景引擎与演示场景 `DemoScenarios`。
- `AgentHost`:子进程、工具链定位、Agent 注册表、Bridge(进程内 HTTP MCP,挂在 `LocalGateway`)、终端沙箱。
- `ClaudeAgentKit`:Claude Code 原生 ACP 适配器(纯 Swift,驱动 `claude` stream-json;`CLI/`、`Translate/`、`Session/`、`Permissions/`),项目不依赖 Node。
- `ChatKit`:会话模型 `SessionModel`、时间线、补全、Markdown、计划、提供商与模型映射、会话存档、用量与缓存统计(无视图)。
- `WorkbenchKit`:工作台模型:多项目、会话树、布局与持久化、停靠 `DockHost`、搜索索引、工作树(无视图)。
- `EditorCore`(原生 Monaco 级编辑器内核,无视图;迁移计划见 `.specstory/history/docs/` 的「编辑器内核迁移」文档):持久化文本绳 `TextRope`、撤销栈、共享文档 `EditorDocument`,后续加入选区/折叠/换行/装饰/View Zone 视图模型。
- `ClaudeConfigKit`(`~/.claude`、`.mcp.json`)、`DiffKit`、`EditorKit`(高亮、tree-sitter、Markdown 就地渲染)、`GitKit`、`LSPKit`。
- `ProviderProxyKit`:本机回环网关 `LocalGateway` 与模型代理(Anthropic 透传 / OpenAI 转换);真实密钥只在代理内存。
- `MermaidKit`、`IconKit`(Lucide、`OMFileIcon`、品牌图标;界面禁用 SF Symbol)、`DesignSystem`(令牌、主题包、玻璃材质)。
- `SpreadsheetKit`、`CanvasKit`、`AutomationKit`、`DemoKit`、`IDEKit`(IDE 模式模型,视图在 `OhMyAgentApp/IDE/`)、`OMLog`(日志、`AppEnv` 路径隔离)。
- `OhMyAgentApp`:应用本体(SwiftUI/AppKit 视图)。Agent 窗口是 SwiftUI `Window` 场景,IDE 窗口是 AppKit `NSWindow`(不用 `WindowGroup`);代码块、命令输出、Diff、表格、Markdown 文字统一用 AppKit 只读文本叶子(`OMReadOnlyTextView` 等,跨叶子选择由 `SelectionHub` 接管)。
- `FakeAgent`、`ACPSpike`/`EditorSpike`:辅助/验证用可执行目标。
- 新增模块请登记在本节、模块地图文档与「开发进度.md」的代码索引中。

## 2. 常用命令
- 构建并组装应用:`Scripts/bundle.sh [debug|release|dev]`(`dev` 生成 `build/OhMyAgent Dev.app`,Bundle ID `com.ixxxxoooo.OhMyAgent.dev`)
- 重启**开发版**(只结束开发版及其子进程 → 构建 → 启动,不影响稳定版):`Scripts/restart.sh`(默认 `dev`;`OMA_AGENT=fake` 使用脚本化 Agent;`OMA_DEMO=1` 进入演示模式)
- 更新**稳定版**:在系统 Terminal.app 里运行 `Scripts/promote.sh`(release 构建 → 安装到 `/Applications/OhMyAgent.app`)
- 本地签名证书(一次性,免费):`Scripts/make-signing-cert.sh` 创建自签 `OhMyAgent Local Dev`,`bundle.sh` 自动使用,TCC 权限不再因重编译失效;勿删该证书(可导出备份)
- 稳定版/开发版隔离:数据目录 `Application Support/OhMyAgent[-Dev]`、日志 `Logs/OhMyAgent[-Dev]` 由 `AppEnv`(`OMLog`)统一提供,**新增落盘路径必须经 `AppEnv.supportDirectory`,禁止再硬编码 `"OhMyAgent"`**;开发版首次启动从稳定版复制数据与偏好(只复制不回写)
- 演示模式(隔离沙盒 + 脚本化 Agent,测试会话流/工具卡/子 Agent/Git 的首选方式):`Scripts/demo.sh [--reset] [--scenario <名>]`(自动转发全部 `OMA_*` 变量);无人值守导览截图:`Scripts/demo-tour.sh [步骤前缀...]`;完整指南 `.specstory/history/docs/20261016_演示模式自动化演示指南.md`
- 本地 CI(本地化扫描 + 中文资源同步检查 + UI 规范扫描 + 零警告构建 + 全部测试 + plist/strings 校验;`OMA_CI_PERF=1` 时追加 release 构建与性能浸泡,结束清理测试临时目录):`Scripts/ci.sh`
- 运行单元测试:`Scripts/test.sh [参数]`(结束后自动清理测试遗留在系统临时目录的目录;勿直接长期使用 `swift test`,macOS 的 `NSTemporaryDirectory()` 不读 `TMPDIR`,无法隔离)。清理历史遗留:`Scripts/clean-test-tmp.sh [--dry-run]`;新增测试若使用新的临时目录前缀,请加到该脚本的 `PREFIXES`
- 性能门槛:`Scripts/perf.sh`;演示空间基准(项目打开/1 万文件索引/长会话加载/复制/渲染/模型与引擎切换/内存):`Scripts/demo-bench.sh [--only 分类] [--keep]`;发布:`Scripts/release.sh`
- 日志:`Scripts/logs.sh`(子命令 `tail|os|grep|open|last|report|mem|slow|turn`)
- 其他脚本:`acp-diff.py`(原生适配器 vs Node 版差分对照,需自备 Node 版放在 `OMA_NODE_ADAPTER`)、`publish.sh`、`perf-soak.sh`/`perf-ui.sh`/`perf-report.py`(性能)、`mock-anthropic.py`、`real-agent-probe.py`(真实 ACP 适配器探针,含 OpenCode)、`token-probe.py`(token/缓存实测)、`ui-lint.py`(UI 规范扫描,见 4.2)
- 推送前 CI 钩子默认**不运行**(`.githooks/pre-push` 仅在 `OMA_PREPUSH_CI=1 git push` 时才跑 `Scripts/ci.sh`);钩子目录已启用:`git config core.hooksPath .githooks`

## 3. 开发流程(必须遵守)
1. 开发前先读「开发进度.md」,优先复用现有代码,避免重复造轮子。
2. **每修改完一个功能点或修复完一个问题(含样式微调、小 Bug),必须先提交(并 push),再执行 `Scripts/restart.sh` 重启应用**,确认改动真实生效;顺序固定为「改完 → 提交 → 重启」,不得省略、不得推迟,不要攒多个功能/修复再一起提交。
   - **CI 只在用户手动运行或明确说「测试 / CI」时才执行**;提交、push、重启流程中一律不自动跑 `Scripts/ci.sh`。
   - 重启后若发现问题,按新的修复另起一次提交(`fix: …`),不要改写已推送的提交。
3. **每完成一个功能点就提交一次**:一次提交只包含一个功能或修复,不要把多个功能混在一起;
   提交信息使用**中文 Conventional Commits**(`feat: …`、`fix: …`、`refactor: …`、`test: …`、`docs: …`、`chore: …`)。
4. **每次提交后立即 `git push`** 到远端 `origin/main`(`origin` = https://github.com/ixxxxoooo/OhMyAgent.git)。
5. 功能完成后更新「开发进度.md」(里程碑状态、代码索引、偏差说明)。
6. 禁止提交:`build/`、`dist/`、`.build/`、日志文件、任何密钥或令牌。
7. 文档放 `.specstory/history/docs/yyyyMMdd_功能名称.md`;SQL 放 `.specstory/history/sql/`。

## 4. Swift 最佳实践
- Swift 6 严格并发,零警告(`-warnings-as-errors`)。UI 与视图模型标注 `@MainActor`;共享可变状态用 `actor` 隔离;跨并发边界的类型必须 `Sendable`。
- 状态管理用 `@Observable`(Observation),视图保持小而纯;大视图拆分为子视图;避免在 `body` 内做耗时计算或 I/O。
- 值类型(`struct`/`enum`)优先;类仅用于需要引用语义或身份的场景;访问控制取最小(默认 `internal`,`private` 优先)。
- 禁止强制解包(`!`)、`try!`、`as!`、`fatalError` 处理可恢复错误;空值判断使用 `isEmpty`/可选绑定;错误使用明确的 `Error` 类型并向上传递或记录。
- 异步用 `async/await` 与结构化并发(`Task`、`TaskGroup`),避免回调嵌套与 `DispatchQueue` 手写同步(系统 API 桥接除外)。
- 主线程不得做磁盘/网络/子进程阻塞操作;热路径(流式渲染、滚动、输入)避免不必要的分配与视图重建。
- 方法 ≤ 300 行(用户全局规则的“单文件 ≤ 300 行”在本仓库为新增文件的目标,存量大文件如 `SessionModel.swift` 逐步拆分,生成数据文件除外);命名:类型 UpperCamelCase,方法/变量 lowerCamelCase,常量不使用全大写下划线风格(遵循 Swift API 设计准则)。
- 注释一律中文;每个类型与方法写文档注释(用途、参数、返回值);文件头含 `@author ixxxxoooo`。
- 对外接口入参做合法性校验。
- 测试使用 Swift Testing(`@Test`/`#expect`),新功能必须带测试;测试不得依赖真实模型或网络。
- 本地化(中英双语):界面文案用字面量(中文为开发语言,键为中文原文),新增文案必须同步 `Resources/en.lproj/Localizable.strings`;以 `String` 传入的文案(`NSMenu` 标题、`panel.prompt`、三目表达式、含插值的 `Label(_:om:)` 等)用 `String(localized:)`;插值占位符须与运行时类型一致(`Int`→`%lld`、`String`→`%@`,`Int32` 先转 `Int`)。
  - `zh-Hans.lproj/Localizable.strings` 由 `Scripts/sync-zh-strings.py` 自动生成(恒等映射),禁止手改;`InfoPlist.strings` 管应用名与版权。开发区域为 `en`(非中文系统回退英文)。
  - 批量追加译文用 `Scripts/add-strings.py`;`Scripts/l10n-scan.py --check` 扫描遗漏的中文字面量(豁免项在脚本 `ALLOWLIST`),已接入 `Scripts/ci.sh`。
  - Bundle ID 为 `com.ixxxxoooo.OhMyAgent`;旧域 `com.ygw.OhMyAgent` 的偏好由 `LegacyDefaultsMigration` 首次启动时一次性迁移。
- 无障碍:仅图标的控件必须有 `accessibilityLabel`;动画经 `omWithAnimation` 以遵循「减弱动态效果」。

## 4.1 界面配色与布局约定
- 左侧栏、设置页左栏背景统一取 `OMColors.sidebar`(`SidebarBackground`);中间内容区(会话流、编辑区、设置页右侧)与右侧栏背景统一取 `OMColors.surface` / `OMColors.contentBackground`。
- **`#EFEFEF`(侧栏)/`#F6F6F7`(内容区)只属于「跟随系统」浅色与「Cursor 浅色」主题**;其他主题(深色、Anthropic、Claude Code、OpenCode 等)必须在 `ThemePalette` 里提供各自的 `surface` 与 `sidebarBackground`(未提供时才由内容色与前景混合推导),禁止把这两个色值套到所有主题。新增主题必须同时给出内容色与侧栏色,并保证 `sidebar != surface`(`ThemePackageTests`/`PaperThemeTests`/`CustomThemeTests` 守卫)。
- 深色与主题包由令牌派生,禁止在视图里写死色值或另起背景材质。
- 设置页左栏宽度必须与工作台左栏一致(取 `WorkbenchModel.layout.leftWidth`),切换设置页时侧栏不跳动。
- 搜索入口统一为中央搜索窗(⌘K,`HubSearch`):新增可搜索的内容类型时,在 `HubCandidateBuilder` 里加候选并补 `HubSearchEngineTests`。
- 文件与文件夹的展示(chip、工具行、搜索结果、改动列表、补全)统一使用彩色文件类型图标 `OMFileIcon`,不要用通用文档图标。
- 悬浮在输入区附近的新卡片/弹窗(吸附消息、消息编辑窗等)沿用底部输入框的样式(`omGlassCard`、圆角、内边距),不要另起一套。

## 4.2 UI 组件与字号规范(全局唯一一套,所有界面遵守)
`Scripts/ui-lint.py --check`(已接入 `Scripts/ci.sh`)会扫描 `Sources/OhMyAgentApp`;确需特例时在该行末尾写 `// ui-lint:allow 原因`。

**字号**:只能用 `OMFonts` 令牌(随「界面字号」缩放),禁止 `.font(.system(size:…))`:
- `title`(15 半粗):页面/弹窗标题;`sectionTitle`(13 半粗):设置页分组标题;
- `body`(13.5):正文、设置行标题、列表主文本;`small`(11.5):次要文字、按钮、说明;`caption`(11):脚注、标签、状态栏;
- `mono`(12.5)/`monoSmall`(11.5):代码与等宽;`reading`/`readingMono`:仅会话时间线(额外乘「时间线字号」);
- 令牌覆盖不到的特例(Markdown 标题、徽标数字、搜索大输入框)使用 `OMFonts.custom(size, weight:, design:)`,仍随界面字号缩放。
- 工具栏/面板里的紧凑控件(过滤栏、标签条、输出面板)高度 24pt,字号 `small`/`caption`,不得出现比 `small` 更大的控件字。

**颜色**:一律 `OMColors`(`accent`、`danger`、`success`、`warning`、`secondaryText`、`tertiaryText`、`hairline`、`card`、`surface`、`sidebar`、`onAccent`),禁止 `Color.red/.green/.orange/.white`、写死 RGB、`foregroundStyle(.red)`。

**图标**:只用 `Image.om`/`Label(_:om:)`(Lucide),禁止 SF Symbol;三档尺寸 12(行内)/14(工具条)/16(标题);颜色走 `OMColors`;仅图标控件必须 `omTooltip` 与 `accessibilityLabel`(系统 `.help` 禁用,见下方「悬浮提示」)。复制一律 `copy`,成功后短暂变 `check`(统一用 `OMCopyButton`),禁止 `doc.on.doc`/`checkmark` 作为复制图标。

**按钮**(`OMButtonStyle`,`DesignSystem/UIControls.swift`):`.omPrimary`(主操作,每个区域至多一个)、`.omSecondary`(次操作)、`.omPlain`(文字按钮)、`.omDestructive`(破坏性)、`.omIcon`(仅图标);默认紧凑 24pt,大表单底部主按钮可用 `OMButtonStyle(.primary, size: .regular)`(28pt)。禁止 `.bordered/.borderedProminent/.borderless` 与 `.controlSize(.large)`。

**选择与数值控件**:
- 少量互斥选项:工具条/标题栏用 `OMCompactSegmented`,设置表单内可用系统 `.segmented` 选择器;开关用 `OMSwitch`(行内说明用设置行的 `Toggle`,固定 `.small`);
- 档位/数值调节(宽度、字号等)用 `OMStepSlider`(带刻度的横向滑块),不用下拉;
- 下拉式选择(模型、模式、思考强度、分支、面包屑、Agent、标签溢出、日志级别等)统一用 `OMPickList`:无箭头浮层、顶部搜索、↑↓ 切换、回车选中、Esc 关闭、当前项打勾;不使用 `.popover`/`Menu`/`.pickerStyle(.menu)` 做选择。

**右键菜单与对话框**:右键菜单只用 `omContextMenu { OMMenuItem… }`(`OhMyAgentApp/Menu/OMContextMenu.swift`),禁止 `.contextMenu`;模态对话框只用 `OMDialog.confirm/prompt/alert` 或 `OMModal.run`(`Dialog/OMDialog.swift`),禁止 `NSAlert`;`ui-lint.py` 的「菜单」「对话框」规则守卫。自动化验证这类自绘子窗口用键盘,不要依赖合成点击。

**设置页**:分组标题 `sectionTitle`;行标题 `body`;说明 `Note`(`caption` + `secondaryText`);所有数字输入用 `SettingsNumericField`;右侧内容宽度由「外观 → 设置页宽度」统一控制;页面骨架用 `SettingsForm`/`ExtensionPage`,不要自己拼 `ScrollView`。
**悬浮提示**:全应用只有一套 `omTooltip`(`DesignSystem/Tooltip.swift`,独立面板显示,不会被裁切/遮挡),禁止系统 `.help`(`ui-lint.py` 的「提示」规则守卫)。样式随主题:纸感(`allowsGlass == false`)= 不透明卡片 + 发丝线、无阴影;玻璃主题 = Liquid Glass + 系统阴影。其他公共浮层/组件同理,必须按「纸感 vs 玻璃」分别验证。
**浮层与卡片**:沿用 `omGlassCard`、`OMMetrics.cardRadius`/`controlRadius`;阴影、描边用令牌,不另起一套。

## 4.3 主题渗透规范(所有界面必须跟随主题)
- **颜色只来自 `OMColors` / `ThemePalette`**:前景、次要/三级文字、分隔线、填充(`subtleFill/hoverFill/selectedFill/pressedFill`)、状态(`statusActive/Running/Waiting/Unread/Idle`)、遮罩(`scrim`)、阴影(`shadowInk`)、图表序列(`chart(_:)`)都有令牌;`Color.primary/.secondary/.black/.white`、`NSColor.label/.separatorColor` 等系统色一律禁止(`Scripts/ui-lint.py` 扫描 `Sources/OhMyAgentApp`、`EditorKit`、`MermaidKit` 等)。
- **读取令牌即自动刷新**:`ThemeRuntime` 的读取走 `ThemeTracker.revision`(Observation),视图 `body` 里读 `OMColors.*` 即可随主题热更新,**不要**靠 `.id(...)` 强制重建;AppKit 桥接(终端、编辑器、托盘)监听 `ThemeRuntime.didChange` 重新应用。
- **新增主题**须同时提供:`surface`、`sidebarBackground`、`accent/accent2`、语法色、Diff 色、状态色;可选 `style`(圆角/描边/阴影/玻璃/填充倍率)与 `ansi`(16 色,缺省由状态色推导)。`ThemeTokenTests` 守卫对比度与 ANSI 完整性。
- **终端、编辑器、聊天代码块、Mermaid、Git 图谱、状态点**都从主题取色:终端 `OMTerminalPalette`,Mermaid 经 `ThemeBridges` 注册 `MermaidTheme`,代码高亮缓存键包含主题 id。
- **字号补充**:空状态用 `body`/`small`;紧凑控件不超过 `small`(`OMFonts.custom` 的使用范围见 4.2)。
- **例外**:模式/思考强度选择器沿用原生 `Menu`(无搜索,选项极少),其余下拉统一 `OMPickList`。

## 4.4 Cursor 纸感设计规范(默认主题「Cursor 纸感」,全文见 `.specstory/history/docs/20261017_UI设计规范_Cursor纸感.md`)
- **结构规则对所有主题生效,取值由主题提供**:字重、按钮层级、圆角令牌、三档阴影、强调色角色统一;色板、圆角大小、是否玻璃由 `ThemeStyle`/`ThemePalette` 决定。
- **字重**:文字字重上限 `medium`(`OMFonts.title/sectionTitle` 已为 medium);标题统一用 `OMFonts.title`;字体一律系统字体,禁止衬线(`omEditorialHeading` 仅作备用令牌,默认不使用)。内容强调(搜索命中、ANSI 加粗)可 `// ui-lint:allow 原因`。
- **圆角**:只用 `OMRadius`(`tag/control/card/floating/modal`),禁止字面量 `cornerRadius: N`;标签/芯片/徽标用 `OMPillShape`,`Capsule()` 仅限轨道类几何。间距用 `OMSpacing`(4 的倍数),动效用 `OMMotion.standard`。
- **阴影与玻璃**:阴影只用 `omCardShadow/omFloatingShadow/omFloatShadow` 三档;`ThemeStyle.allowsGlass == false` 的主题(纸感)一律不透明卡片 + 发丝线;禁止装饰性渐变与发光(渐变只作遮罩/淡出,需 `ui-lint:allow`)。
- **颜色角色(强调色渗透)**:选中背景 `selectedFill`、主按钮填充 `actionFill`、全局 `.tint`、进度/加载(`OMSpinner`)、会话状态点(`OMSessionDot`,运行实心呼吸 / 等待空心环 / 未读静止点)、托盘状态点一律跟随主题强调色(`statusActive/statusRunning/statusWaiting/statusUnread`);小字号文字用 `accentText`(纸感为加深 Ember,保证对比度),主按钮在提供 `accentText` 的主题里用同色相加深版;「继续/执行计划」用 `.omWarm`(Amber),「提交/完成」用 `.omPositive`(Forest);同组实心按钮至多两个。禁止纯 `#FFFFFF`/`#000000`。系统 `ProgressView` 不跟随 tint,加载一律用 `OMSpinner`。
- **守卫**:`Scripts/ui-lint.py` 的字重/圆角/胶囊/渐变规则与 `PaperThemeTests`(对比度、sidebar ≠ surface、旧主题默认值不变)已接入 CI。

## 5. 日志规范(P1 起强制)
- 只使用 `OMLog`(`Log.<category>.info/debug/warning/error`),禁止 `print`/`NSLog`。
- 日志文件:`~/Library/Logs/OhMyAgent/`;排查问题先看这里。
- 日志需包含关联标识(sessionId / requestId / toolCallId)与耗时;每个 `catch` 必须记录上下文。
- 严禁记录令牌、`ANTHROPIC_*`、`Authorization`、完整环境变量;协议载荷默认不记录,需经脱敏器。

## 6. UI 验证约定(不抢焦点)
- 启动:`open -g -n build/OhMyAgent.app --env OMA_AGENT=fake --env OMA_PROJECT_ROOT=$PWD`。
- 演示模式:`OMA_DEMO=1`、`OMA_DEMO_ROOT`、`OMA_DEMO_RESET=1`、`OMA_DEMO_SCENARIO=<场景名>`、`OMA_THEME=<主题 id>`;输入框 `/demo-<场景名>` 或命令面板「演示场景」运行场景;**新增工具卡/条目类型必须补演示场景**(覆盖守卫测试会失败提醒)。
- 调试钩子(`OMA_*`,预置界面状态、打开页面、性能基准等)的完整清单与用法见 `.specstory/history/docs/20261023_调试钩子清单.md`,以 `grep -rn OMA_ Sources` 为准;`Scripts/restart.sh` 只转发 `OMA_AGENT`/`OMA_DEMO`,其他钩子用 `open -g -n … --env`。
- 截图用 `screencapture -x -o -l<windowId>`;禁止用 osascript 发送按键;验证后删除截图。

## 7. 安全
- 不读取 Keychain 中的 OAuth 令牌;官方 `claude` 使用自己的凭据。
- Developer ID 分发,非沙盒;签名与公证脚本见 `Scripts/release.sh`。
