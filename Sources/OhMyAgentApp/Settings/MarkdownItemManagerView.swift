// @author ixxxxoooo
// 技能(Skills 与命令)/ 子 Agent 设置页:按来源分组的卡片列表、搜索、新建向导、源码编辑(含 frontmatter 快捷开关)、删除。
// 参考 Cursor 的「Rules, Skills, Subagents」版式;读写沿用 ClaudeConfigKit 的 `SkillStore` / `AgentStore`。

import IconKit
import AppKit
import ClaudeConfigKit
import DesignSystem
import SwiftUI

/// 技能或子 Agent 设置页(两者结构相同,用 kind 区分)。
struct SkillsSettingsPage: View {
    let center: ConfigCenter
    let kind: MarkdownItem.Kind
    /// 顶栏搜索词(由自定义页传入)
    var query = ""
    @State private var showCreate = false
    @State private var editing: MarkdownItem?
    @State private var pendingDelete: MarkdownItem?

    private var items: [MarkdownItem] {
        let all = kind == .agent ? center.snapshot.agents : Self.filtered(center.snapshot.skills, kind: kind)
        guard !query.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(query) || $0.description.localizedCaseInsensitiveContains(query) }
    }
    /// 内置子 Agent(Claude Code 自带,无需配置):Explore 用于快速只读检索,输入框 `/explore` 是快捷入口。
    private var builtinAgents: some View {
        VStack(alignment: .leading, spacing: 8) {
            ExtensionSectionLabel(title: String(localized: "内置"), count: 1)
            ExtensionCardList {
                ExtensionRow(icon: "search", title: "Explore",
                             subtitle: String(localized: "快速、只读地检索代码库并回答问题;配合 search_code 索引搜索。在输入框用 /explore 提问。")) {
                    OMTag("/explore", tint: OMColors.accent)
                } trailing: {
                    EmptyView()
                }
            }
        }
    }

    /// 技能页只显示 Skill、命令页只显示斜杠命令(两者共用 `SkillStore` 扫描结果)。
    static func filtered(_ items: [MarkdownItem], kind: MarkdownItem.Kind) -> [MarkdownItem] {
        items.filter { kind == .command ? $0.kind == .command : $0.kind != .command }
    }

    private var total: Int { kind == .agent ? center.snapshot.agents.count : Self.filtered(center.snapshot.skills, kind: kind).count }
    private var noun: String {
        switch kind {
        case .agent: return String(localized: "子 Agent")
        case .command: return String(localized: "命令")
        case .skill: return String(localized: "技能")
        }
    }
    private var pageIcon: String { kind == .agent ? "person.2" : (kind == .command ? "terminal" : "sparkles") }
    private var pageSubtitle: String {
        switch kind {
        case .agent: return String(localized: "给 Claude 配置可委派任务的专用子 Agent,定义保存在 ~/.claude/agents 或项目的 .claude/agents。")
        case .command: return String(localized: "把常用提示词保存成斜杠命令,在输入框用 /命令名 触发,保存在 ~/.claude/commands 或项目的 .claude/commands。")
        case .skill: return String(localized: "用 SKILL.md 扩展 Claude 的能力,保存在 ~/.claude/skills 或项目的 .claude/skills。")
        }
    }

    var body: some View {
        ExtensionPage(
            center: center, icon: pageIcon, title: noun,
            subtitle: pageSubtitle
        ) {
            Button { center.reload() } label: { Image.om("arrow.clockwise") }
                .buttonStyle(.omIcon)
                .omTooltip("重新读取")
                .accessibilityLabel("刷新")
            Button { showCreate = true } label: { Label(String(localized: "新建\(noun)"), om: "plus") }
                .buttonStyle(.omPrimary)
        } content: {
            if kind == .agent { builtinAgents }
            if items.isEmpty {
                ExtensionEmptyCard(
                    icon: pageIcon,
                    title: total == 0 ? String(localized: "还没有\(noun)") : String(localized: "没有匹配的\(noun)"),
                    message: String(localized: "点击右上角「新建\(noun)」创建,或安装带有\(noun)的插件。")
                )
            } else {
                ForEach(grouped, id: \.0) { title, group in
                    ExtensionSectionLabel(title: title, count: group.count)
                    ExtensionCardList {
                        ForEach(Array(group.enumerated()), id: \.element.id) { index, item in
                            if index > 0 { ExtensionRowDivider() }
                            row(item)
                        }
                    }
                }
            }
        }
        .task(id: total) {
            // 调试钩子:OMA_OPEN_ITEM=<名称片段> 自动打开对应条目的编辑弹窗(用于 UI 验证)
            guard editing == nil, let key = ProcessInfo.processInfo.environment["OMA_OPEN_ITEM"], !key.isEmpty else { return }
            editing = items.first { $0.name.localizedCaseInsensitiveContains(key) }
        }
        .sheet(item: $editing) { item in
            MarkdownItemEditorSheet(center: center, item: item, onDelete: { pendingDelete = item }) { editing = nil }
        }
        .sheet(isPresented: $showCreate) {
            switch kind {
            case .agent: AgentCreateSheet(center: center) { showCreate = false }
            case .command: CommandCreateSheet(center: center) { showCreate = false }
            case .skill: SkillCreateSheet(center: center) { showCreate = false }
            }
        }
        .confirmationDialog("删除\(noun)?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), presenting: pendingDelete) { item in
            Button("移到废纸篓", role: .destructive) {
                center.perform(String(localized: "已删除 \(item.name)")) {
                    if kind == .agent { try AgentStore(paths: center.paths).delete(item) } else { try SkillStore(paths: center.paths).delete(item) }
                }
                editing = nil
            }
        } message: { item in
            Text("「\(item.name)」会被移到废纸篓。")
        }
    }

    /// 按来源分组(保持首次出现的顺序)。
    private var grouped: [(String, [MarkdownItem])] {
        var order: [String] = []
        var groups: [String: [MarkdownItem]] = [:]
        for item in items {
            let key = item.source.displayName
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(item)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }

    private func icon(for item: MarkdownItem) -> String {
        switch item.kind {
        case .agent: return "person.2"
        case .command: return "terminal"
        case .skill: return "sparkles"
        }
    }

    private func row(_ item: MarkdownItem) -> some View {
        ExtensionRow(
            icon: icon(for: item), title: item.kind == .command ? "/\(item.name)" : item.name,
            subtitle: item.description, dimmed: item.overriddenBy != nil,
            onTap: { editing = item },
            badges: {
                if item.kind == .command { Tag(String(localized: "命令")) }
                if item.disableModelInvocation { Tag(String(localized: "仅手动")) }
                if let over = item.overriddenBy { Tag(String(localized: "被\(over.displayName)覆盖"), color: OMColors.warning) }
                if item.isSymlink { Tag(String(localized: "链接")) }
                if item.source.isReadOnly { Tag(String(localized: "只读"), color: OMColors.tertiaryText) }
            },
            trailing: {
                HStack(spacing: 6) {
                    if item.kind == .agent || item.userInvocable {
                        Button {
                            AppActions.shared.insertIntoComposer(item.kind == .agent ? "@agent-\(item.name) " : "/\(item.name) ")
                        } label: { Image.om("message-square-plus", size: 14).frame(width: 24, height: 24).contentShape(Rectangle()) }
                            .buttonStyle(.plain)
                            .foregroundStyle(OMColors.secondaryText)
                            .omTooltip(item.kind == .agent ? String(localized: "回到对话并 @ 提及这个子 Agent") : String(localized: "回到对话并插入这个命令"))
                            .accessibilityLabel("在对话中使用")
                    }
                    Menu {
                        Button("编辑…") { editing = item }
                        Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([item.fileURL]) }
                        if !item.source.isReadOnly {
                            Divider()
                            Button("删除…", role: .destructive) { pendingDelete = item }
                        }
                    } label: {
                        Image.om("ellipsis", size: 14).frame(width: 24, height: 24).contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel("更多操作")
                }
            }
        )
    }
}

/// 编辑弹窗:条目编辑器 + 底部「完成」。
struct MarkdownItemEditorSheet: View {
    let center: ConfigCenter
    let item: MarkdownItem
    let onDelete: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            MarkdownItemEditor(center: center, item: item, onDelete: onDelete)
            Divider()
            HStack {
                Spacer()
                Button("完成", action: onClose).keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(width: 780, height: 600)
        .background(OMColors.surface)
    }
}

/// 条目编辑器:快捷开关 + 源码编辑。
struct MarkdownItemEditor: View {
    let center: ConfigCenter
    let item: MarkdownItem
    let onDelete: () -> Void

    @State private var text = ""
    @State private var original = ""

    private var isDirty: Bool { text != original }
    private var parsed: MarkdownDocument { MarkdownDocument(parsing: text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(item.name).font(OMFonts.title)
                Tag(item.source.displayName, color: OMColors.accent2)
                Spacer()
                if item.kind == .agent || item.userInvocable {
                    Button {
                        AppActions.shared.insertIntoComposer(item.kind == .agent ? "@agent-\(item.name) " : "/\(item.name) ")
                    } label: { Label("在对话中使用", om: "message-square-plus") }
                        .buttonStyle(.omSecondary)
                        .omTooltip(item.kind == .agent ? String(localized: "回到对话并 @ 提及这个子 Agent") : String(localized: "回到对话并插入这个命令"))
                }
                Button { NSWorkspace.shared.activateFileViewerSelecting([item.fileURL]) } label: { Image.om("folder") }
                    .buttonStyle(.omIcon)
                    .omTooltip("在 Finder 中显示").accessibilityLabel("在 Finder 中显示")
                if !item.source.isReadOnly {
                    Button("还原") { text = original }.buttonStyle(.omSecondary).disabled(!isDirty)
                    Button("保存", action: save).buttonStyle(.omPrimary).disabled(!isDirty).keyboardShortcut("s", modifiers: .command)
                    Button("删除", role: .destructive, action: onDelete).buttonStyle(.omDestructive)
                }
            }
            Text(item.fileURL.abbreviatingHome).font(OMFonts.caption).foregroundStyle(OMColors.secondaryText).lineLimit(1).truncationMode(.middle)
            if item.source.isReadOnly {
                Label("来自插件,只读。如需修改请到「插件」页管理。", om: "lock").font(OMFonts.small).foregroundStyle(OMColors.secondaryText)
            } else if item.kind != .agent {
                HStack(spacing: 18) {
                    Toggle("允许模型自动调用", isOn: Binding(
                        get: { !(parsed.bool("disable-model-invocation") ?? false) },
                        set: { value in mutate { $0.setBool("disable-model-invocation", value ? nil : true) } }))
                    Toggle("可由用户手动调用", isOn: Binding(
                        get: { parsed.bool("user-invocable") ?? true },
                        set: { value in mutate { $0.setBool("user-invocable", value ? nil : false) } }))
                }
                .toggleStyle(.checkbox).font(OMFonts.small)
            }
            if !text.isEmpty, !parsed.hasFrontmatter, item.kind != .command {
                Label("缺少 frontmatter(--- 包裹的头部),Claude 可能无法识别描述。", om: "exclamationmark.triangle").font(OMFonts.small).foregroundStyle(OMColors.warning)
            }
            MarkdownDocumentPane(text: $text, isReadOnly: item.source.isReadOnly)
        }
        .padding(16)
        .onAppear(perform: load)
        .onChange(of: item.fileURL) { _, _ in load() }
        .onChange(of: center.snapshot.skills.count + center.snapshot.agents.count) { _, _ in if !isDirty { load() } }
    }

    private func load() {
        let content = (try? String(contentsOf: item.fileURL, encoding: .utf8)) ?? ""
        text = content
        original = content
    }

    private func mutate(_ change: (inout MarkdownDocument) -> Void) {
        var doc = parsed
        change(&doc)
        text = doc.render()
    }

    private func save() {
        let doc = MarkdownDocument(parsing: text)
        let ok = center.perform(String(localized: "已保存 \(item.name)")) {
            if item.kind == .agent { try AgentStore(paths: center.paths).save(doc, to: item) } else { try SkillStore(paths: center.paths).save(doc, to: item) }
        }
        if ok { original = text }
    }
}

/// 新建 Skill 向导。
struct SkillCreateSheet: View {
    let center: ConfigCenter
    let onClose: () -> Void
    @State private var name = ""
    @State private var description = ""
    @State private var template: SkillTemplate = .manual
    @State private var scope: ConfigScope = .user

    private var problems: [String] {
        name.range(of: "^[a-z0-9][a-z0-9-]{0,63}$", options: .regularExpression) == nil ? [String(localized: "名称只能包含小写字母、数字和连字符")] : []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("新建 Skill").font(OMFonts.title)
            FormRow(label: String(localized: "名称"), hint: String(localized: "同时是斜杠命令名:/\(name.isEmpty ? "name" : name)")) { TextField("code-review", text: $name).textFieldStyle(.omField) }
            FormRow(label: String(localized: "描述")) { TextField("它做什么、何时使用", text: $description).textFieldStyle(.omField) }
            FormRow(label: String(localized: "模板")) {
                Picker("", selection: $template) { ForEach(SkillTemplate.allCases) { Text($0.displayName).tag($0) } }.pickerStyle(.segmented).labelsHidden()
            }
            FormRow(label: String(localized: "位置")) {
                Picker("", selection: $scope) { Text("用户").tag(ConfigScope.user); Text("项目").tag(ConfigScope.project) }.pickerStyle(.segmented).labelsHidden()
            }
            SheetFooter(problems: problems, confirmTitle: String(localized: "创建"), onCancel: onClose) {
                if center.perform(String(localized: "已创建 \(name)"), { try SkillStore(paths: center.paths).create(name: name, description: description, template: template, scope: scope) }) { onClose() }
            }
        }
        .padding(20)
        .frame(width: 500)
    }
}

/// 新建子 Agent 向导。
struct AgentCreateSheet: View {
    let center: ConfigCenter
    let onClose: () -> Void
    @State private var name = ""
    @State private var description = ""
    @State private var tools = ""
    @State private var model = ""
    @State private var prompt = ""
    @State private var scope: ConfigScope = .user

    private var problems: [String] {
        var result: [String] = []
        if name.range(of: "^[a-z0-9][a-z0-9-]{0,63}$", options: .regularExpression) == nil { result.append(String(localized: "名称只能包含小写字母、数字和连字符")) }
        if description.trimmingCharacters(in: .whitespaces).isEmpty { result.append(String(localized: "请填写描述,Claude 依据它决定何时委派")) }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("新建子 Agent").font(OMFonts.title)
            FormRow(label: String(localized: "名称")) { TextField("code-reviewer", text: $name).textFieldStyle(.omField) }
            FormRow(label: String(localized: "描述")) { TextField("何时应该委派给它", text: $description).textFieldStyle(.omField) }
            FormRow(label: String(localized: "工具"), hint: String(localized: "逗号分隔,留空表示继承全部工具")) { TextField("Read, Grep, Glob", text: $tools).textFieldStyle(.omField) }
            FormRow(label: String(localized: "模型"), hint: String(localized: "可选:sonnet / opus / haiku / inherit")) { TextField("留空继承", text: $model).textFieldStyle(.omField) }
            FormRow(label: String(localized: "系统提示")) {
                TextEditor(text: $prompt).font(OMFonts.mono).frame(height: 110).settingsEditorStyle()
            }
            FormRow(label: String(localized: "位置")) {
                Picker("", selection: $scope) { Text("用户").tag(ConfigScope.user); Text("项目").tag(ConfigScope.project) }.pickerStyle(.segmented).labelsHidden()
            }
            SheetFooter(problems: problems, confirmTitle: String(localized: "创建"), onCancel: onClose) {
                let list = tools.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                if center.perform(String(localized: "已创建 \(name)"), { try AgentStore(paths: center.paths).create(name: name, description: description, tools: list, model: model, prompt: prompt, scope: scope) }) { onClose() }
            }
        }
        .padding(20)
        .frame(width: 540)
    }
}
