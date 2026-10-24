> @author ixxxxoooo  
> 日期: 2026-10-24  
> 主文档: [20261024_重构规格_02_Agent窗口外壳与布局.md](./20261024_重构规格_02_Agent窗口外壳与布局.md)

# 附录 B：workbench.json Schema、补遗规格与响应式矩阵

---

## B.1 workbench.json 总览

| 项 | 说明 |
| --- | --- |
| 路径 | `{AppEnv.supportDirectory}/workbench.json`（稳定版 `OhMyAgent`，开发版 `OhMyAgent-Dev`） |
| 编码 | JSON，`JSONEncoder`：`sortedKeys`、日期 **ISO8601**、**无** `prettyPrinted` |
| **Schema 版本号** | **无顶层 `version` 字段**；靠字段缺失容错 + `LegacyKeys` 迁移 |
| 损坏处理 | 解码失败 → 复制为 `workbench.json.corrupt` → 加载返回 `nil` → 默认状态；后续 `save` **不覆盖** corrupt 备份 |
| 启动 clamp | `WorkbenchLayout.clamp()`；Dock 经 `restoredForLaunch` + `sanitize()` |

---

## B.2 顶层 `WorkbenchState`

| 字段 | 类型 | 默认 | 说明 |
| --- | --- | --- | --- |
| `layout` | `WorkbenchLayout` | 见 B.3 | 三栏显隐、宽度、侧栏模式、面板换边等 |
| `projects` | `[ProjectEntry]` | `[]` | 含会话区 `isChatArea` 条目；磁盘不存在项启动时隐藏但仍可写回 |
| `selectedProjectID` | `String?` | `nil` | 标准化目录路径 |
| `dock` | `DockLayout?` | 缺省→空布局 | **中栏**停靠 |
| `rightDock` | `DockLayout?` | 缺省→空布局 | **右栏**停靠 |
| `otherDocks` | `PaneDocks?` | `nil` | 非当前 `leftPane` 模式的 dock 快照 |
| `chatSlots` | `[ChatSlotRecord]?` | `nil` | 退出时仍有内容的会话标签，用于恢复 sessionId |

**不持久化（内存/UI）**：`NavHistory`、`ClosedTabStack`、`paneMemory`、`rightExpanded`、`maximizedGroupID`（恢复时清空）、`layout.legacyMigration`。

---

## B.3 `WorkbenchLayout` 全部字段

| 字段 | 类型 | 默认值 | 持久化键 | clamp / 迁移 |
| --- | --- | --- | --- | --- |
| `leftVisible` | `Bool` | `true` | ✓ | — |
| `rightVisible` | `Bool` | `false` | ✓ | — |
| `leftWidth` | `Double` | **260** | ✓ | **200…520** |
| `rightWidth` | `Double` | **480** | ✓ | 下限 240；上限动态见主文档 |
| `leftPane` | `LeftPane` | **`sessions`** | ✓ | 未知→`sessions`；`available` 仅 `sessions`/`workspaces` |
| `placement` | `PanelPlacement` | sidebar **left**, tools **right** | ✓ | 见 B.4 |
| `fileOpenTarget` | `OpenTarget` | **`right`** | ✓ | `auto`/`right`/`editor`；设置 UI 只写 right/editor |
| `terminalListWidth` | `Double` | **180** | ✓ | **120…320** |
| `terminalListCollapsed` | `Bool` | `false` | ✓ | — |
| `filesTreeWidth` | `Double` | **260** | ✓ | **200…480** |
| `filesTreeCollapsed` | `Bool` | **`true`** | ✓ | 旧 `{}` 解码亦为 true |

### B.3.1 旧版 `LegacyKeys`（同文件内额外键，解码后写入 `legacyMigration` 一次性消费）

| 旧键 | 用途 |
| --- | --- |
| `bottomVisible`, `bottomPane` | 底部面板终端/输出 |
| `terminalVisible`, `outputVisible` | 侧栏终端/输出 |
| `rightPane` | 旧右栏单视图（如 `git`） |
| `placement.terminal`, `placement.output` | 若 `terminal==editor` 且 bottom 终端可见 → **不迁移** |

`applyLegacyMigration()`：打开 `oma-tools:*` / 终端 / 输出标签并 `rightVisible = true`。

---

## B.4 面板摆放编码（无 PanelOrder / PaneOrder）

源码中 **不存在** `PanelOrder`、`PaneOrder` 类型；持久化与拖放只用下列模型：

| 概念 | 运行时 | JSON |
| --- | --- | --- |
| 面板条目 | `PanelItem`: `sidebar` / `tools` | **不写入 JSON**（由 `placement` 推导） |
| 拖放载荷 | `oma-panel:sidebar` / `oma-panel:tools` | — |
| 落点区域 | `PanelZone`: `left` / `right` | — |
| 持久化 | `PanelPlacement` | `{ "sidebarSide": "left"\|"right", "toolsSide": "left"\|"right" }` |

同侧列顺序 **固定**：由外向内 **sidebar → tools**（`PanelColumn.allCases` 过滤）。

---

## B.5 `ProjectEntry`（项目 / 会话区）

| 字段 | 类型 | 默认 | 说明 |
| --- | --- | --- | --- |
| `id` | `String` | — | 标准化绝对路径 |
| `name` | `String` | 目录名 | 可 `renameProject`（仅显示名） |
| `addedAt`, `lastOpenedAt` | `Date` | ISO8601 | |
| `pinned` | `Bool` | `false` | 项目置顶 |
| `collapsed` | `Bool` | `false` | 折叠会话列表 |
| `sessions` | `[CachedSession]` | `[]` | 侧栏历史缓存 |
| `pinnedSessions` | `[String]` | `[]` | sessionId 列表，顺序=置顶先后 |
| `archivedSessions` | `[String]` | `[]` | 归档 |
| `deletedSessions` | `[String]` | `[]` | **墓碑**：引擎刷新不再加回侧栏 |
| `isChatArea` | `Bool` | `false` | 通用会话区（不在工作区列表展示） |
| `icon` | `ProjectIcon?` | `null` | `{ "kind": "symbol"\|"emoji"\|"image", "value": "..." }` |
| `extraFolders` | `[String]` | `[]` | 多根工作区附加路径 |
| `worktree` | `WorktreeLink?` | `null` | `{ "origin", "branch", "base" }` |

### B.5.1 `CachedSession`

| 字段 | 说明 |
| --- | --- |
| `sessionId`, `title`, `updatedAt`, `createdAt`, `firstSeenAt`, `agentId` | 侧栏排序用 `stableKey`（createdAt 优先） |

### B.5.2 `ChatSlotRecord`

| 字段 | 说明 |
| --- | --- |
| `projectID`, `slot`, `sessionId`, `agentId`, `title` | 对应 `ConversationKey`；重启后在原 chat 标签恢复会话 |

---

## B.6 `DockLayout` 与分屏树

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `root` | `DockNode` | 递归：`group` 或 `split` |
| `focusedGroupID` | `UUID` | 最后聚焦的标签组 |
| `maximizedGroupID` | `UUID?` | 运行时最大化；**持久化可带值但启动 `restoredForLaunch` 会清空** |

### B.6.1 `DockNode` JSON 形态（Swift `Codable` 合成）

**标签组叶子**：

```json
"group": {
  "id": "UUID",
  "tabs": [ /* WorkbenchTab */ ],
  "activeID": "UUID 或 null"
}
```

**分屏节点**：

```json
"split": {
  "id": "UUID",
  "axis": "horizontal | vertical",
  "children": [ /* DockNode 数组 */ ],
  "ratios": [0.5, 0.5]
}
```

根对象示例：`{ "root": { "group": { ... } }, "focusedGroupID": "..." }`

### B.6.2 `WorkbenchTab`

| 字段 | 类型 | 默认 |
| --- | --- | --- |
| `id` | `UUID` | 新建时生成 |
| `kind` | `TabKind` | — |
| `title` | `String` | |
| `isPreview` | `Bool` | `false` |
| `isPinned` | `Bool` | `false` |
| `isDirty` | `Bool` | `false` |
| `line` | `Int?` | 打开定位行（1 起） |

### B.6.3 `TabKind` 全部 case 与 JSON（与 `ConversationTabTests` / 合成编码一致）

关联值对象 **键名即参数名**；可选 `slot` 可省略（旧文件兼容）。

| case | JSON 示例 |
| --- | --- |
| `chat(projectID, slot?)` | `{"chat":{"projectID":"/path/to/proj","slot":"optional-slot"}}` 或 `{"chat":{"projectID":"/path/to/proj"}}` |
| `subagent(projectID, toolCallID)` | `{"subagent":{"projectID":"…","toolCallID":"…"}}` |
| `file(path)` | `{"file":{"path":"/abs/path/file.swift"}}` |
| `diff(path)` | `{"diff":{"path":"…"}}` |
| `changes(projectID)` | `{"changes":{"projectID":"…"}}` |
| `terminal(id)` | `{"terminal":{"id":"bottom:/project/root"}}` 或任意终端 id |
| `agentTerminal(projectID, terminalID)` | `{"agentTerminal":{"projectID":"…","terminalID":"…"}}` |
| `preview(id)` | `{"preview":{"id":"oma-output"}}` 等，见下表 |
| `history(projectID, path?)` | `{"history":{"projectID":"…","path":null}}` 或带 path |
| `blame(path)` | `{"blame":{"path":"…"}}` |
| `commitDiff(root, commit, path)` | `{"commitDiff":{"root":"…","commit":"…","path":"…"}}` |

**`preview(id)` 常用 id（非独立 TabKind case，统一走 preview）**：

| id 前缀/常量 | 含义 |
| --- | --- |
| `oma-tools:files` / `search` / `git` | 右栏工具面板（`RightPane.rawValue`） |
| `oma-output` | 输出面板 |
| `oma-plan:{文件路径}` | 计划文档 |
| `oma-browser:{…}` | 浏览器（重启 `restoredForLaunch` **剔除**） |
| `oma-automation` | 自动化页 |
| `oma-customize` | 自定义页 |
| `oma-demo-metrics` | 演示指标 |
| `oma-canvas:{canvasId}` | 画布 |
| 其它 | Mermaid 等 `openPreview` 注册的 id |

**不存在**名为 `files` / `demoMetrics` / `tools` 的 TabKind case；它们要么是 `preview(id:)` 要么是 `file(path)`。

### B.6.4 `PaneDocks`（`otherDocks`）

```json
"otherDocks": {
  "dock": { /* DockLayout */ },
  "rightDock": { /* DockLayout */ },
  "rightVisible": false
}
```

对应当前 **非激活** 的 `leftPane`（会话 ↔ 代码）下的中/右 dock 与右栏显隐。

### B.6.5 `sanitize()` / `restoredForLaunch` 规则摘要

| 步骤 | 行为 |
| --- | --- |
| `dedupe` | 全局 `TabKind` 去重（文件路径 canonical） |
| `collapseEmptyGroups` | 移除空组；单子节点 split 提升 |
| `fixRatios` | 比例和 1、每项 > 0 |
| `restoredForLaunch` | 删 subagent/agentTerminal/浏览器预览/无效 plan/无项目 chat/不存在文件等；右栏 `keepsPanels: true` 保留终端与 tools 预览 |
| chat 保留 | `chatSlots` 中有记录的会话标签保留；否则每项目最多留 **1** 个空白 chat |

---

## B.7 完整 JSON 示例（示意）

```json
{
  "chatSlots": [
    {
      "agentId": "claude-code",
      "projectID": "/Users/me/proj",
      "sessionId": "sess-abc",
      "slot": "tab-slot-1",
      "title": "实现登录"
    }
  ],
  "dock": {
    "focusedGroupID": "A1B2C3D4-E5F6-7890-ABCD-EF1234567890",
    "root": {
      "group": {
        "activeID": "F1E2D3C4-B5A6-9780-1234-567890ABCDEF",
        "id": "A1B2C3D4-E5F6-7890-ABCD-EF1234567890",
        "tabs": [
          {
            "id": "F1E2D3C4-B5A6-9780-1234-567890ABCDEF",
            "isDirty": false,
            "isPinned": false,
            "isPreview": false,
            "kind": {
              "chat": {
                "projectID": "/Users/me/proj",
                "slot": "tab-slot-1"
              }
            },
            "title": "实现登录"
          }
        ]
      }
    }
  },
  "layout": {
    "fileOpenTarget": "right",
    "filesTreeCollapsed": true,
    "filesTreeWidth": 260,
    "leftPane": "workspaces",
    "leftVisible": true,
    "leftWidth": 260,
    "placement": {
      "sidebarSide": "left",
      "toolsSide": "right"
    },
    "rightVisible": true,
    "rightWidth": 480,
    "terminalListCollapsed": false,
    "terminalListWidth": 180
  },
  "otherDocks": {
    "dock": {
      "focusedGroupID": "00000000-0000-0000-0000-000000000001",
      "root": {
        "group": {
          "activeID": null,
          "id": "00000000-0000-0000-0000-000000000001",
          "tabs": []
        }
      }
    },
    "rightDock": {
      "focusedGroupID": "00000000-0000-0000-0000-000000000002",
      "root": {
        "group": {
          "activeID": null,
          "id": "00000000-0000-0000-0000-000000000002",
          "tabs": []
        }
      }
    },
    "rightVisible": false
  },
  "projects": [
    {
      "addedAt": "2026-10-24T12:00:00Z",
      "archivedSessions": [],
      "collapsed": false,
      "deletedSessions": [],
      "extraFolders": [],
      "id": "/Users/me/proj",
      "isChatArea": false,
      "lastOpenedAt": "2026-10-24T14:00:00Z",
      "name": "proj",
      "pinned": false,
      "pinnedSessions": [],
      "sessions": []
    }
  ],
  "rightDock": {
    "focusedGroupID": "B2C3D4E5-F6A7-8901-BCDE-F12345678901",
    "root": {
      "group": {
        "activeID": "C3D4E5F6-A7B8-9012-CDEF-123456789012",
        "id": "B2C3D4E5-F6A7-8901-BCDE-F12345678901",
        "tabs": [
          {
            "id": "C3D4E5F6-A7B8-9012-CDEF-123456789012",
            "isDirty": false,
            "isPinned": false,
            "isPreview": false,
            "kind": {
              "preview": {
                "id": "oma-tools:files"
              }
            },
            "title": "文件"
          }
        ]
      }
    }
  },
  "selectedProjectID": "/Users/me/proj"
}
```

（UUID 与日期仅为示意；实际写入时键名按 `sortedKeys` 排序。）

---

## B.8 ⇧⌘T、`NavHistory`、`paneMemory`、融合模式

### B.8.1 关闭栈与 `reopenClosedTab`

| 项 | 行为 |
| --- | --- |
| 入栈 | `closeTab` 对 **任意 host** 的标签 `closedTabs.push`（`ClosedTabStack` 容量 **20**） |
| 不可恢复 | `.terminal`、`.agentTerminal`、`.preview`（`ClosedTabStack.isRestorable`） |
| **⇧⌘T** | `reopenClosedTab()` **始终** `dock.open` + `dock.activate`（**仅中栏**） |
| 已知缺口 | 自 **右栏** 关闭的 `file` / `oma-tools:*` 等虽入栈，恢复时仍落到 **中栏**；若需右栏恢复须改实现 |

### B.8.2 `NavHistory`（⌘[ / ⌘]）

| 项 | 说明 |
| --- | --- |
| 记录 | `recordNavigation()` 只 push **`dock`（中栏）** `focusedGroup?.activeID` |
| 触发 | `WorkbenchView` 的 `navigationSignature` 仅观察 **中栏** `focusedGroup` 与 **中栏** tab 数 |
| 右栏 | 激活右栏标签 **不写入** nav；标题栏回退/前进 **不会** 在右栏标签间导航 |
| 设计含义 | 浏览器式历史仅针对 **编辑区/会话标签**；工具栏标签用标签条或 `focusRightTab` 切换 |
| prune | 关闭中栏标签时从栈移除对应 id |

### B.8.3 `paneMemory`（不持久化）

| 项 | 说明 |
| --- | --- |
| 存储 | `WorkbenchModel.paneMemory: [LeftPane: PaneMemory]`，**仅内存** |
| 写入 | `switchLeftPane` 前保存当前 `projectID` + `focusedActiveTab?.id` |
| 恢复 | 切回模式时 `select(project)` + `activateTab`；无记录则代码模式选第一个工作区项目 / 会话模式进会话区 |
| 重启 | 丢失；靠 `otherDocks` + dock 内聚焦 chat 启发式（`WorkbenchModel+PaneMemory`） |
| 与 JSON | `otherDocks` **会** 持久化两套 dock；`paneMemory` **不会** |

### B.8.4 融合模式（Agent 窗口一侧）

| 项 | 说明 |
| --- | --- |
| 偏好键 | `ClientPrefs.Key.fusionMode` = `"general.fusionMode"`，**默认 false** |
| 设置文案 | 外观 →「开启融合模式」；共用会话/草稿/标签；切 IDE 前 **saveAll** |
| Agent → IDE | `switchToIDE`：IDE 窗口 **adoptFusionFrame** Agent 外框，**finishFusionReveal** 后 **隐藏** Agent（非全屏来源窗） |
| IDE → Agent | `switchToAgent` → `showMainWindow(adopting:replacing:)` 同上反向；**仅当 Agent 成功显示** 才隐藏 IDE |
| 从 IDE 调设置/新对话 | `showMainWindow` 检测 `fusionMode && isIDE` → **不新开窗**，走 `switchToAgent()` 并保留 `workbench.mode` |
| 启动 | `fusionLastIDEKey`：上次 IDE 模式才 `restoreWindows`；纯 Agent 退出则 **不恢复 IDE**；恢复 IDE 后 **orderOut** Agent（最多等 6s） |
| ⌥ IDE | 仍 **forceNew** IDE 窗口，不沿用融合换框 |
| 全屏 | `fusionSource` 为 nil → 普通两窗并存，无原地隐藏 |

`WorkbenchModel+Fusion` 仅提供 IDE Agent 面板读 **中栏** `chatTabs(in:)`，不改变 Agent 窗口布局。

---

## B.9 `ProjectSwitcherButton`（输入区左上角）

> 位置在 **会话输入区** 左上（非侧栏）；详见文档 03，此处写外壳规格。

| 项 | 值 |
| --- | --- |
| 触发 | 点击 chip 切换 `shown` |
| 尺寸 | 高 **22 pt**；水平 padding **6**；`OMPillShape` 悬停/展开时 `hoverFill` |
| 文案 | 会话区：**「无项目」** + 图标 `square-slash`；否则项目 `name` 或目录名 + `folder` 12 pt + `chevron-down` 9 pt |
| 字号 | `OMFonts.caption`，secondaryText |
| Tooltip | 「切换项目」 |
| a11y | 「当前项目: {title}」 |
| 浮层 | `omCustomPicker`，**宽 220**，placement **below** |

### B.9.1 浮层结构 `ProjectPickerPopover`

| 区块 | 内容 |
| --- | --- |
| 搜索 | 高 **32**，placeholder「搜索项目」，`search` 12 pt；**打开后 ~40ms 聚焦** |
| 列表 | 项目行高 **26**；maxHeight **240**；当前项 `check` accent |
| 空搜索 | 「没有匹配的项目」caption |
| 操作区 | 见下表 |
| 底部 | 「无项目」`square-slash`，当前会话区时 checked |

| 操作 id | 标题 | 图标 | 行为 |
| --- | --- | --- | --- |
| `action:openFolder` | 打开文件夹 | folder-open | `WorkspaceStore.chooseDirectory` → openWorkspace |
| `action:newProject` | 新建项目 | folder-plus | 同上（与打开文件夹相同入口） |
| `action:quickStart` | 快速启动 | folder-symlink | `createQuickStartDirectory` → Documents/OhMyAgent/QuickStart_* |
| `action:noProject` | 无项目 | square-slash | `newGeneralConversation()` |

**键盘**：↑↓ 在 `filteredProjects + 4 个 action + noProject` 循环；Esc 关闭；Return `confirmSelection`；搜索框 Return 同确认。

**项目行来源**：`workspaceProjects` + `RecentStore.projects()` 去重（不含 isChatArea）。

---

## B.10 `ProjectIconView` / 更换图标

| kind | 展示 | 尺寸 |
| --- | --- | --- |
| `nil` | `folder` / `folder-open`（expanded） | 默认 **14 pt**，框 **16×16** |
| `symbol` | Lucide `value` | 14 pt；选中 accent |
| `emoji` | 单字符 Text | `OMFonts.custom(size)` |
| `image` | 缩略图 max 64px → 显示 **size+2** 圆角 tag | 失败回退 folder |

**更换图标对话框**（`OMModal` 宽 **440**）：符号网格 10×36 cell；预设 24 emoji；「输入任意表情」；「选择图片…」（≤10MB，png/jpeg/gif/heic/tiff/webp/icns）；「恢复默认」；取消/完成。

侧栏 **无**「首字母」自动生成图标。

---

## B.11 `WorkspaceCreator` 弹窗

| 项 | 值 |
| --- | --- |
| 容器 | `OMModal.run(width: **460**)` |
| 标题 | 「添加工作区」`OMFonts.title` |
| 说明 | 「选择一个或多个项目文件夹(它们是平级的):Agent、搜索、文件树与 Git 面板会同时覆盖它们。」 |
| 名称 | 可选 TextField placeholder「默认使用第一个文件夹名」，高 **28** |
| 文件夹列表 | 空态「尚未添加文件夹」minHeight **40**；有项时每行 folder 14 + 名 + 路径 caption + 移除 x 22 |
| 添加 | 「添加文件夹…」→ `NSOpenPanel` 多选目录，prompt「添加」 |
| 校验 | `WorkspaceFolders.validate`：互不包含、不重复；失败 `draft.error` danger caption |
| 按钮 | 取消 `-1`；「创建」默认键，**folders 为空 disabled** |
| 成功 | `openWorkspace(首个路径)` → 可选 `renameProject` → `addFolder` 其余 → 刷新索引 |

---

## B.12 侧栏菜单与对话框补遗

| 场景 | 文案 |
| --- | --- |
| 重命名项目 | 标题「重命名项目」；说明「只修改侧栏里的显示名,不会改动磁盘上的目录名。」 |
| 重命名会话 | 标题「重命名会话」；initial=当前标题 |
| 删除会话 | 标题「删除会话」；运行中「「{title}」正在运行,删除会立即中断它,且无法恢复。」/ 否则「将被永久删除…」；确认「删除」destructive |
| 关闭脏文件标签 | 「要保存对 {文件名} 的修改吗?」；「如果不保存,你的修改将会丢失。」保存/不保存/取消 |

**墓碑**：`deleteSession` / `forgetSession` → `deletedSessions`；引擎历史刷新不再出现。

**归档**：`archivedSessions`；筛选菜单「显示已归档会话」。

---

## B.13 区域 × 折叠/拖拽/关闭 行为矩阵

| 区域 | 折叠/收起 | 拖拽改尺寸 | 拖拽换位置 | 关闭/移除 | 主要快捷键 |
| --- | --- | --- | --- | --- | --- |
| 项目栏 sidebar | ⌘B / 顶栏开关；Compact <780 自动 | 左 PanelResizer；200–520 | 「工作区」标题条 → 左/右半窗 | 仅隐藏，不销毁项目 | ⌘B |
| 右栏 tools | ⌘⌥B；Compact 自动；会话模式强制关 | 右 PanelResizer；240–动态 max | 工作区标题条（tools 手柄在 RightDock 内，见 tools 标签页头） | 隐藏栏；标签 ⌘W 单关 | ⌘⌥B / ⌘J 终端 |
| 中栏 dock 标签 | 会话模式隐藏标签栏 | 分屏 OMSplitHandle | 标签/会话/文件 → 组内/边缘 | ⌘W；中键关 | ⌃Tab / ⌘1–9 / ⇧⌘T |
| 右栏 dock 标签 | 随右栏隐藏 | 同左 | 同左 | 同左 | 同左 |
| TitlebarOverlay | — | — | — | — | ⌘K 搜索 / ⌘[/] nav |
| RightRail | — | — | — | — | 点击展开右栏 |
| TerminalDropOverlay | — | — | 面板 sidebar/tools 换边 | — | — |
| 设置 mode | 占满窗口 | — | — | 返回工作台 | ⌘, |
| WelcomeView | — | — | — | — | 打开项目/无项目会话 |
| HubOverlay | Esc | — | — | 关闭浮层 | ⌘K |

---

## B.14 窗口宽度响应式阶梯（480 → 2000）

| 宽度条件 | 系统反应 |
| --- | --- |
| **< 480** | 低于 `WorkbenchView` minWidth；系统仍可能强制最小 480 |
| **480 – 779** | 常规三栏；若左+中栏最小(200+400) > 可用宽，列宽 **clamp 后 clip**（中栏仍声明 min 400） |
| **< 780** | `CompactLayout` **进入**：自动 `leftVisible=false` / `rightVisible=false`（若原为开）并标记 autoCollapsed |
| **780 – 819** | 回差区：保持 compact 状态不变 |
| **≥ 820** | **退出** compact：仅恢复 autoCollapsed 且仍收起的栏 |
| **项目栏宽 ≈ 260** | 默认宽；`sidebarSwitchFitsInStrip`：左浮层≈198 + 模式切换 54 + 8 **≤ 260** 时模式切换在 **35pt 顶条内** |
| **项目栏 < ~260** | 模式切换 **换行**到顶条下方（额外 ~35+6 pt） |
| **右栏 max** | `window - (左栏可见宽) - 400`；例：**1280** 默认 → 1280−260−400=**620** 可拖上限 |
| **2000** | 同上公式；右栏可拖到约 **2000−260−400=1340**（仍 ≥240） |
| **rightExpanded** | 右栏占满除项目栏外宽度；中栏 width 0，不销毁视图 |
| **融合切换** | 与宽度无关；全屏时融合 adopt **禁用** |

---

*附录 B 结束*
