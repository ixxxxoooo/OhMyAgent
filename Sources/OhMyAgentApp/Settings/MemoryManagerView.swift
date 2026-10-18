// @author ixxxxoooo
// 记忆与指令:多层级 CLAUDE.md / rules 编辑器,规则创建与删除。

import IconKit
import ClaudeConfigKit
import DesignSystem
import SwiftUI

/// 记忆管理页。
struct MemoryManagerView: View {
    let center: ConfigCenter
    /// 顶栏搜索词(由自定义页传入),过滤文件列表
    var query = ""
    @State private var selectedID: String?
    @State private var showCreateRule = false
    @State private var showLoadOrder = true

    private var allFiles: [MemoryFile] { center.snapshot.memory }
    private var files: [MemoryFile] {
        query.isEmpty ? allFiles : allFiles.filter { $0.title.localizedCaseInsensitiveContains(query) || $0.url.path.localizedCaseInsensitiveContains(query) }
    }
    private var selected: MemoryFile? { allFiles.first { $0.id == selectedID } }

    var body: some View {
        VStack(spacing: 0) {
            loadOrderSection
            Divider()
            listDetail
        }
        .sheet(isPresented: $showCreateRule) { RuleCreateSheet(center: center) { showCreateRule = false } }
    }

    /// 「规则加载顺序」:按 Claude Code 的加载先后列出带序号的步骤,后加载的优先级更高;点击步骤跳到对应文件。
    private var loadOrderSection: some View {
        let steps = MemoryStore.loadOrder(of: allFiles)
        return VStack(alignment: .leading, spacing: 6) {
            Button { omWithAnimation(.snappy(duration: 0.15)) { showLoadOrder.toggle() } } label: {
                HStack(spacing: 6) {
                    Image.om(showLoadOrder ? "chevron-down" : "chevron-right", size: 12).foregroundStyle(OMColors.tertiaryText)
                    Text("规则加载顺序").font(OMFonts.small.weight(.medium)).foregroundStyle(OMColors.secondaryText)
                    Text("后加载的优先级更高").font(OMFonts.caption).foregroundStyle(OMColors.tertiaryText)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("规则加载顺序")
            if showLoadOrder {
                VStack(spacing: 2) {
                    ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in loadStepRow(index + 1, step) }
                }
            }
        }
        .padding(.horizontal, OMSpacing.md)
        .padding(.vertical, OMSpacing.sm)
    }

    /// 一步:序号 + 位置 + 状态;点击选中该位置的第一个文件。
    private func loadStepRow(_ number: Int, _ step: MemoryLoadStep) -> some View {
        let target = step.files.first { $0.exists } ?? step.files.first
        let isSelected = target.map { $0.id == selectedID } ?? false
        return Button { selectedID = target?.id } label: {
            HStack(spacing: 10) {
                Text(verbatim: "\(number)")
                    .font(OMFonts.caption.monospacedDigit()).foregroundStyle(OMColors.accentText)
                    .frame(width: 20, height: 20)
                    .background(OMColors.selectedFill, in: OMPillShape())
                Text(verbatim: step.title).font(OMFonts.small).lineLimit(1)
                Spacer(minLength: 8)
                if step.files.count > 1 { Tag(String(localized: "\(step.files.count) 个文件")) }
                Tag(step.exists ? String(localized: "已存在") : String(localized: "未创建"), color: step.exists ? OMColors.success : OMColors.tertiaryText)
            }
            .padding(.horizontal, OMSpacing.sm).padding(.vertical, 3)
            .background(isSelected ? OMColors.selectedFill : Color.clear, in: RoundedRectangle(cornerRadius: OMRadius.control, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("第 \(number) 步:\(step.title)")
    }

    private var listDetail: some View {
        ListDetail {
            VStack(spacing: 0) {
                HStack {
                    Button { showCreateRule = true } label: { Label("新建规则", om: "plus") }
                        .buttonStyle(.omSecondary)
                    Spacer()
                }
                .padding(OMSpacing.md)
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(files) { file in fileRow(file) }
                    }
                    .padding(.horizontal, OMSpacing.sm)
                    .padding(.bottom, OMSpacing.sm)
                }
            }
        } detail: {
            if let file = selected {
                MemoryEditor(center: center, file: file).id(file.id)
            } else {
                EmptyHint(icon: "brain", title: String(localized: "选择一个文件"), message: String(localized: "记忆文件会在每次会话开始时作为上下文加载。"))
            }
        }
        .task(id: files.count) {
            // 调试钩子:OMA_OPEN_ITEM=<标题片段> 自动选中对应记忆文件(用于 UI 验证)
            guard selectedID == nil, let key = ProcessInfo.processInfo.environment["OMA_OPEN_ITEM"], !key.isEmpty else { return }
            selectedID = files.first { $0.title.localizedCaseInsensitiveContains(key) }?.id
        }
    }

    /// 列表里的一行:标题 + 状态/路径过滤标签;选中态用主题 `selectedFill`,不用系统列表的选中色。
    private func fileRow(_ file: MemoryFile) -> some View {
        let isSelected = file.id == selectedID
        return Button { selectedID = file.id } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(file.title).font(OMFonts.body).lineLimit(1)
                OMFlowLayout(spacing: 4) {
                    Tag(file.exists ? String(localized: "已存在") : String(localized: "未创建"), color: file.exists ? OMColors.success : OMColors.tertiaryText)
                    if !file.isLoadedByDefault { Tag(String(localized: "Claude 默认不读取"), color: OMColors.warning) }
                    ForEach(file.pathFilters.prefix(2), id: \.self) { Tag($0) }
                }
            }
            .padding(.horizontal, OMSpacing.sm)
            .padding(.vertical, OMSpacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? OMColors.selectedFill : Color.clear, in: RoundedRectangle(cornerRadius: OMRadius.control, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: OMRadius.control, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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
                    Button("删除", role: .destructive) { confirmDelete = true }.buttonStyle(.omDestructive)
                }
                Button("还原") { text = original }.buttonStyle(.omSecondary).disabled(!isDirty)
                Button(file.exists ? String(localized: "保存") : String(localized: "创建并保存"), action: save).buttonStyle(.omPrimary)
                    .disabled(!isDirty && file.exists).keyboardShortcut("s", modifiers: .command)
            }
            Text(file.url.abbreviatingHome).font(OMFonts.caption).foregroundStyle(OMColors.secondaryText).lineLimit(1).truncationMode(.middle)
            if file.kind == .agentsMD {
                Label("Claude Code 不会自动读取 AGENTS.md。可在 CLAUDE.md 中写 @AGENTS.md 导入它。", om: "info.circle").font(OMFonts.small).foregroundStyle(OMColors.secondaryText)
            }
            if file.kind == .local {
                Label("CLAUDE.local.md 只对你个人生效,请加入 .gitignore。", om: "info.circle").font(OMFonts.small).foregroundStyle(OMColors.secondaryText)
            }
            // 规则文件的 frontmatter(如 paths)可在属性面板编辑;普通 CLAUDE.md 不主动加头部
            MarkdownDocumentPane(text: $text, allowsCreatingProperties: file.kind == .userRule || file.kind == .projectRule)
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
            FormRow(label: String(localized: "文件名")) { TextField("swift-style", text: $name).textFieldStyle(.omField) }
            FormRow(label: String(localized: "适用路径"), hint: String(localized: "可选,逗号分隔 glob,如 **/*.swift;留空表示始终加载")) { TextField("", text: $paths).textFieldStyle(.omField).font(OMFonts.mono) }
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
