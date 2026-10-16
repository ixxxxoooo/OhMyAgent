// @author ixxxxoooo
// 记忆与指令:多层级 CLAUDE.md / rules 编辑器,规则创建与删除。

import IconKit
import ClaudeConfigKit
import DesignSystem
import SwiftUI

/// 记忆管理页。
struct MemoryManagerView: View {
    let center: ConfigCenter
    @State private var selectedID: String?
    @State private var showCreateRule = false

    private var files: [MemoryFile] { center.snapshot.memory }
    private var selected: MemoryFile? { files.first { $0.id == selectedID } }

    var body: some View {
        ListDetail {
            VStack(spacing: 0) {
                HStack {
                    Button { showCreateRule = true } label: { Label("新建规则", om: "plus") }
                    Spacer()
                }
                .padding(10)
                List(files, selection: $selectedID) { file in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(file.title).font(OMFonts.body).lineLimit(1)
                        HStack(spacing: 4) {
                            Tag(file.exists ? String(localized: "已存在") : String(localized: "未创建"), color: file.exists ? .green : .gray)
                            if !file.isLoadedByDefault { Tag(String(localized: "Claude 默认不读取"), color: OMColors.warning) }
                            ForEach(file.pathFilters.prefix(2), id: \.self) { Tag($0) }
                        }
                    }
                    .tag(file.id)
                    .accessibilityElement(children: .combine)
                }
                .listStyle(.inset)
            }
        } detail: {
            if let file = selected {
                MemoryEditor(center: center, file: file).id(file.id)
            } else {
                EmptyHint(icon: "brain", title: String(localized: "选择一个文件"), message: String(localized: "记忆文件会在每次会话开始时作为上下文加载。"))
            }
        }
        .sheet(isPresented: $showCreateRule) { RuleCreateSheet(center: center) { showCreateRule = false } }
    }
}

/// 记忆文件编辑器。
struct MemoryEditor: View {
    let center: ConfigCenter
    let file: MemoryFile
    @State private var text = ""
    @State private var original = ""
    @State private var confirmDelete = false

    private var isDirty: Bool { text != original }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(file.title).font(OMFonts.title).lineLimit(1)
                Spacer()
                if file.kind == .userRule || file.kind == .projectRule {
                    Button("删除", role: .destructive) { confirmDelete = true }
                }
                Button("还原") { text = original }.disabled(!isDirty)
                Button(file.exists ? String(localized: "保存") : String(localized: "创建并保存"), action: save).buttonStyle(.borderedProminent)
                    .disabled(!isDirty && file.exists).keyboardShortcut("s", modifiers: .command)
            }
            Text(file.url.abbreviatingHome).font(OMFonts.caption).foregroundStyle(OMColors.secondaryText).lineLimit(1).truncationMode(.middle)
            if file.kind == .agentsMD {
                Label("Claude Code 不会自动读取 AGENTS.md。可在 CLAUDE.md 中写 @AGENTS.md 导入它。", om: "info.circle").font(OMFonts.small).foregroundStyle(OMColors.secondaryText)
            }
            if file.kind == .local {
                Label("CLAUDE.local.md 只对你个人生效,请加入 .gitignore。", om: "info.circle").font(OMFonts.small).foregroundStyle(OMColors.secondaryText)
            }
            TextEditor(text: $text)
                .font(OMFonts.mono)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(OMColors.hairline))
        }
        .padding(16)
        .onAppear { text = MemoryStore(paths: center.paths).read(file); original = text }
        .confirmationDialog("删除规则?", isPresented: $confirmDelete) {
            Button("移到废纸篓", role: .destructive) { center.perform(String(localized: "已删除 \(file.title)")) { try MemoryStore(paths: center.paths).deleteRule(file) } }
        }
    }

    private func save() {
        if center.perform(String(localized: "已保存 \(file.title)"), { try MemoryStore(paths: center.paths).write(text, to: file) }) { original = text }
    }
}

/// 新建规则。
struct RuleCreateSheet: View {
    let center: ConfigCenter
    let onClose: () -> Void
    @State private var name = ""
    @State private var paths = ""
    @State private var scope: ConfigScope = .project

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("新建规则").font(OMFonts.title)
            FormRow(label: String(localized: "文件名")) { TextField("swift-style", text: $name).textFieldStyle(.roundedBorder) }
            FormRow(label: String(localized: "适用路径"), hint: String(localized: "可选,逗号分隔 glob,如 **/*.swift;留空表示始终加载")) { TextField("", text: $paths).textFieldStyle(.roundedBorder).font(OMFonts.mono) }
            FormRow(label: String(localized: "位置")) {
                Picker("", selection: $scope) { Text("用户").tag(ConfigScope.user); Text("项目").tag(ConfigScope.project) }.pickerStyle(.segmented).labelsHidden()
            }
            SheetFooter(problems: name.range(of: "^[A-Za-z0-9_.-]+$", options: .regularExpression) == nil ? [String(localized: "文件名只能包含字母、数字、点、下划线和连字符")] : [],
                        confirmTitle: String(localized: "创建"), onCancel: onClose) {
                let filters = paths.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                if center.perform(String(localized: "已创建规则 \(name)"), { try MemoryStore(paths: center.paths).createRule(name: name, scope: scope, pathFilters: filters) }) { onClose() }
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}
