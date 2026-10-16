// @author ixxxxoooo
// Skills / 命令 / 子 Agent 管理:分组列表、源码编辑(含 frontmatter 快捷开关)、新建向导、删除。

import IconKit
import AppKit
import ClaudeConfigKit
import DesignSystem
import SwiftUI

/// Skills 或子 Agent 管理页(两者结构相同,用 kind 区分)。
struct MarkdownItemManagerView: View {
    let center: ConfigCenter
    let kind: MarkdownItem.Kind
    @State private var selectedID: String?
    @State private var search = ""
    @State private var showCreate = false
    @State private var pendingDelete: MarkdownItem?

    private var items: [MarkdownItem] {
        let all = kind == .agent ? center.snapshot.agents : center.snapshot.skills
        guard !search.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(search) || $0.description.localizedCaseInsensitiveContains(search) }
    }
    private var selected: MarkdownItem? { items.first { $0.id == selectedID } }
    private var noun: String { kind == .agent ? String(localized: "子 Agent") : "Skill" }

    var body: some View {
        ListDetail {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Button { showCreate = true } label: { Label(String(localized: "新建\(noun)"), om: "plus") }
                    Spacer()
                    Button { center.reload() } label: { Image.om("arrow.clockwise") }.help("重新读取").accessibilityLabel("刷新")
                }
                .padding(10)
                TextField("搜索名称或描述", text: $search).textFieldStyle(.roundedBorder).padding(.horizontal, 10).padding(.bottom, 8)
                if items.isEmpty {
                    EmptyHint(icon: kind == .agent ? "person.2" : "sparkles", title: String(localized: "没有\(noun)"), message: String(localized: "点击「新建\(noun)」创建,或安装带有\(noun)的插件。"))
                } else {
                    List(selection: $selectedID) {
                        ForEach(grouped, id: \.0) { title, group in
                            Section(title) {
                                ForEach(group) { item in row(item).tag(item.id) }
                            }
                        }
                    }
                    .listStyle(.inset)
                }
            }
        } detail: {
            if let item = selected {
                MarkdownItemEditor(center: center, item: item) { pendingDelete = item }
                    .id(item.id)
            } else {
                EmptyHint(icon: "doc.text", title: String(localized: "选择一个\(noun)进行查看或编辑"))
            }
        }
        .sheet(isPresented: $showCreate) {
            if kind == .agent { AgentCreateSheet(center: center) { showCreate = false } }
            else { SkillCreateSheet(center: center) { showCreate = false } }
        }
        .confirmationDialog("删除\(noun)?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), presenting: pendingDelete) { item in
            Button("移到废纸篓", role: .destructive) {
                center.perform(String(localized: "已删除 \(item.name)")) {
                    if kind == .agent { try AgentStore(paths: center.paths).delete(item) } else { try SkillStore(paths: center.paths).delete(item) }
                }
                selectedID = nil
            }
        } message: { item in
            Text("「\(item.name)」会被移到废纸篓。")
        }
    }

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

    private func row(_ item: MarkdownItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(item.kind == .command ? "/\(item.name)" : item.name).font(OMFonts.body).lineLimit(1)
                if item.kind == .command { Tag(String(localized: "命令")) }
                if item.disableModelInvocation { Tag(String(localized: "仅手动")) }
                if let over = item.overriddenBy { Tag(String(localized: "被\(over.displayName)覆盖"), color: OMColors.warning) }
                if item.isSymlink { Tag(String(localized: "链接")) }
            }
            if !item.description.isEmpty {
                Text(item.description).font(OMFonts.caption).foregroundStyle(OMColors.secondaryText).lineLimit(2)
            }
        }
        .opacity(item.overriddenBy == nil ? 1 : 0.55)
        .accessibilityElement(children: .combine)
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
                        .help(item.kind == .agent ? String(localized: "回到对话并 @ 提及这个子 Agent") : String(localized: "回到对话并插入这个命令"))
                }
                Button { NSWorkspace.shared.activateFileViewerSelecting([item.fileURL]) } label: { Image.om("folder") }
                    .help("在 Finder 中显示").accessibilityLabel("在 Finder 中显示")
                if !item.source.isReadOnly {
                    Button("还原") { text = original }.disabled(!isDirty)
                    Button("保存", action: save).buttonStyle(.borderedProminent).disabled(!isDirty).keyboardShortcut("s", modifiers: .command)
                    Button("删除", role: .destructive, action: onDelete)
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
            TextEditor(text: $text)
                .font(OMFonts.mono)
                .disabled(item.source.isReadOnly)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(OMColors.hairline))
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
            FormRow(label: String(localized: "名称"), hint: String(localized: "同时是斜杠命令名:/\(name.isEmpty ? "name" : name)")) { TextField("code-review", text: $name).textFieldStyle(.roundedBorder) }
            FormRow(label: String(localized: "描述")) { TextField("它做什么、何时使用", text: $description).textFieldStyle(.roundedBorder) }
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
            FormRow(label: String(localized: "名称")) { TextField("code-reviewer", text: $name).textFieldStyle(.roundedBorder) }
            FormRow(label: String(localized: "描述")) { TextField("何时应该委派给它", text: $description).textFieldStyle(.roundedBorder) }
            FormRow(label: String(localized: "工具"), hint: String(localized: "逗号分隔,留空表示继承全部工具")) { TextField("Read, Grep, Glob", text: $tools).textFieldStyle(.roundedBorder) }
            FormRow(label: String(localized: "模型"), hint: String(localized: "可选:sonnet / opus / haiku / inherit")) { TextField("留空继承", text: $model).textFieldStyle(.roundedBorder) }
            FormRow(label: String(localized: "系统提示")) {
                TextEditor(text: $prompt).font(OMFonts.mono).frame(height: 110).overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(OMColors.hairline))
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
