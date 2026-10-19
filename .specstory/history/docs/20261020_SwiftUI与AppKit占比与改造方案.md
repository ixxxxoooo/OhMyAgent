# SwiftUI 与 AppKit 占比与改造方案(实施记录)

> @author ixxxxoooo · 2026-10-20

## 1. 需求回顾

分析 OhMyAgent 中 SwiftUI 与 AppKit 的使用占比;为了界面不卡顿、会话能多行复制,找出需要优化的地方,判断哪些地方改用 AppKit 更流畅,并给出最佳改造方案。方案按阶段实施,阶段 3 按数据触发。

## 2. 结论

- 项目整体是「SwiftUI 骨架 + AppKit 叶子」:页面、布局、状态全在 SwiftUI;文本编辑器、终端、输入框、右键菜单/对话框底座、托盘、窗口框架等已是 AppKit(`NSViewRepresentable` 桥接)。
- 卡顿与「不能多行复制」的共同根因在会话时间线:代码块、命令输出、Diff、表格由大量 SwiftUI `Text`/`ForEach` 逐行拼成,既重又无法跨块选择。
- 最佳方案不是整页改 AppKit,而是**把「大量静态文字」做成 AppKit 只读文本叶子**,再由一个选择中枢把叶子连成可连续选择的文档;同时把**数千行级列表**从「整树挂载」改成「窗口化挂载」。

## 3. 已实施

### 阶段 0:重内容演示场景与基线
- 演示场景 `heavy-content`(`DemoScenarios+Heavy.swift`):长代码块、大段命令输出、大 Diff、宽表格、长 Markdown。
- 基线(`SCENARIO_LONG=heavy-content Scripts/perf-ui.sh scroll`,release):帧数约 350,平均 28.2ms,掉帧(>33ms)26,单帧最长 308.5ms。

### 阶段 1:AppKit 只读文本叶子
- `OMReadOnlyTextView`(TextKit 1,`OMLeafLayoutManager`):统一的只读、可选、可复制叶子;自定义属性 `omLineFillKey`(行底色)、`omGutterKey`(Diff 行号槽)、`omRuleBelowKey`(表头线)由布局管理器绘制,复制时只得到内容。
- `OMTextLeaf`(`NSViewRepresentable`):按签名重建、尾部增量替换(≥2000 字符)、按 (编辑代数, 宽度) 缓存测量、`sizeThatFits`;无宽度提议时回退 480。
- 已接入:代码块、命令输出(ANSI 色缓存)、用户消息折叠文本、统一/并排 Diff、表格(制表位文本 + 网格线,复制得到 TSV)、Markdown 文字段。

### 阶段 2:SelectionHub 跨叶子连续选择
- `SelectionMath`(ChatKit,纯逻辑):范围换算与拼接(叶子间 `\n\n`,同行叶子 `\n`),9 个单测。
- `SelectionHub`:自管鼠标跟踪循环(`NSTextView` 自带循环会吞掉拖动),用模型坐标 (叶子键, UTF-16 偏移) 表示选区;可见区域裁剪的命中测试;拖到边缘自动滚动(经 `onAutoScroll` 暂停贴底跟随);⌘C、⌘A、右键「复制所选」;卸载叶子时冻结其文本以便仍能复制;11 个单测。
- 验证:真实 CGEvent 拖选跨代码块/表格/输出/Diff/消息,⌘C 内容与模型文本一致。

### 阶段 3(按数据触发)
| 项 | 触发线 | 实测 | 结论 |
| --- | --- | --- | --- |
| 资源管理器文件树 | 展开 ≥5000 行且挂载 >50ms | 5000 文件目录展开后主线程 100% CPU 持续 >40 秒(debug);改 `LazyVStack` 后展开不卡但每次滚动 ~900ms(release) | **触发,已改**:`ExplorerFlatten` 扁平化 + 固定行高窗口挂载;逐行 `onDrop` 是滚动 360ms 的根因(A/B 去掉拖放后为 0),改为列表级单个 `DropDelegate`。结果:展开约 0.1–0.4 秒,滚动无卡顿 |
| 表格/CSV 预览 | ≥1 万行出现掉帧 | 3 万行 CSV(`LazyVStack`)debug 下滚动单帧约 105ms,无持续卡顿 | 未触发,不改 |
| Blame | 行数大且掉帧 | 已是 `LazyVStack`,行内容轻 | 未触发,不改 |

> 与计划的偏差:计划写的是 `NSOutlineView`。实测发现瓶颈不在「SwiftUI 画不动」,而在整树挂载与逐行放置区;扁平化 + 窗口化在保留既有拖放/右键菜单/Git 装饰/多文件夹工作区行为的前提下已解决,改 `NSOutlineView` 收益不足以覆盖重写风险。若以后出现超 5 万行的单目录,再评估。

## 4. 前后数据(release,heavy-content 滚动)

| 指标 | 基线 | 改造后(3 次) | 目标 |
| --- | --- | --- | --- |
| 平均帧间隔 | 28.2ms | 19.7 / 25.2 / 18.4ms | ≤17.5ms |
| 掉帧(>33ms) | 26 | 25 / 51 / 15 | ≤2 |
| 单帧最长 | 308.5ms | 104.8 / 190.5 / 94.4ms | ≤40ms |

结论:最长单帧与平均值明显改善(最长降约 3 倍,平均降约 30%),但**未达到计划目标**,且单次测量抖动大(机器上同时有构建/应用)。debug 下 heavy 场景卡顿数 15 → 1。剩余掉帧主要来自首次进入视口的叶子挂载与测量,后续可继续做:叶子预测量、更大的 overscan、时间线窗口内按需挂载。

## 5. 已知限制
- ⌘A 只选当前已挂载的叶子(时间线只挂载最近 40 轮)。
- `SelectionHub.onAutoScroll` 是全局单闭包,多个会话流同时可见时以最后出现的为准。
- 叶子的 `copyTransform` 必须保持长度不变(选区以 UTF-16 偏移映射)。
- 既有问题(基线同样复现,非本次引入):`heavy-content` 回合结束后时间线底部有一段空白。

## 6. 测试与守卫
- `OMTextLeafTests`、`SelectionHubTests`、`SelectionMathTests`、`ExplorerFlattenTests`(6 个)。
- `PerfSourceGuardTests`:资源管理器逐行不得注册 `onDrop`、必须窗口化挂载。
- 测量与排查经验:`sample` 被 pyenv 同名脚本遮蔽,须用 `/usr/bin/sample`;`ls` 被 eza 覆盖,脚本里用 `command ls`;用 System Events 激活窗口会让进程开启辅助功能,SwiftUI 焦点遍历变贵,性能测量改用 `open -n` 激活。
