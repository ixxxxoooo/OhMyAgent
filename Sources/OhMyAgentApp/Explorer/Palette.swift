// @author ygw
// 命令面板与快速打开:⌘P 模糊查找项目文件,⇧⌘P(或在输入框前加 `>`)执行命令。

import AppKit
import DesignSystem
import IconKit
import SwiftUI
import WorkbenchKit

/// 面板模式。
enum PaletteMode { case files, commands }

/// 面板中的一行。
struct PaletteItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let trailing: String?
    let icon: String
    /// 标题中需要强调的字符位置
    let positions: [Int]
    let run: @MainActor () -> Void
}

@MainActor
@Observable
final class PaletteModel {
    static let shared = PaletteModel()
    var isPresented = false
    var mode: PaletteMode = .files
    var query = "" {
        didSet {
            if query != oldValue { selection = 0 }
            // 在文件模式输入 ">" 切到命令模式
            if mode == .files, query.hasPrefix(">") { mode = .commands; query = String(query.dropFirst()) }
        }
    }
    var selection = 0

    /// 打开面板。
    func present(_ mode: PaletteMode, workbench: WorkbenchModel) {
        self.mode = mode
        query = ""
        selection = 0
        isPresented = true
        if mode == .files, WorkspaceIndexModel.shared.root != workbench.selectedProjectID || WorkspaceIndexModel.shared.files.isEmpty {
            WorkspaceIndexModel.shared.refresh(root: workbench.selectedProjectID)
        }
    }

    func dismiss() { isPresented = false }

    /// 当前查询对应的候选项。
    func items(workbench: WorkbenchModel) -> [PaletteItem] {
        switch mode {
        case .files: return fileItems(workbench: workbench)
        case .commands: return commandItems(workbench: workbench)
        }
    }

    private func fileItems(workbench: WorkbenchModel) -> [PaletteItem] {
        guard let root = workbench.selectedProjectID else { return [] }
        let index = WorkspaceIndexModel.shared
        let candidates = index.root == root ? index.files : []
        return FuzzyMatcher.rank(query: query, in: candidates, limit: 60).map { match in
            let name = (match.path as NSString).lastPathComponent
            let dir = (match.path as NSString).deletingLastPathComponent
            let nameOffset = match.path.count - name.count
            let positions = match.positions.filter { $0 >= nameOffset }.map { $0 - nameOffset }
            return PaletteItem(id: match.path, title: name, subtitle: dir.isEmpty ? nil : dir, trailing: nil, icon: "file", positions: positions) {
                workbench.openFile((root as NSString).appendingPathComponent(match.path), preview: false)
            }
        }
    }

    private func commandItems(workbench: WorkbenchModel) -> [PaletteItem] {
        let all = PaletteCommands.all(workbench: workbench)
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let ranked: [(PaletteCommand, [Int])]
        if trimmed.isEmpty { ranked = all.map { ($0, []) } }
        else {
            ranked = all.compactMap { cmd in FuzzyMatcher.match(query: trimmed, path: cmd.title).map { (cmd, $0.positions, $0.score) } }
                .sorted { $0.2 > $1.2 }.map { ($0.0, $0.1) }
        }
        return ranked.map { cmd, positions in
            PaletteItem(id: cmd.id, title: cmd.title, subtitle: nil, trailing: cmd.shortcut, icon: cmd.icon, positions: positions, run: cmd.run)
        }
    }
}

/// 一条可由命令面板执行的命令。
struct PaletteCommand {
    let id: String
    let title: String
    let icon: String
    let shortcut: String?
    let run: @MainActor () -> Void
}

@MainActor
enum PaletteCommands {
    /// 全部命令(随工作台状态生成)。
    static func all(workbench: WorkbenchModel) -> [PaletteCommand] {
        let store = ShortcutStore.shared
        func key(_ a: ShortcutAction) -> String { store.binding(for: a).display }
        return [
            PaletteCommand(id: "new", title: String(localized: "新对话"), icon: "square-pen", shortcut: key(.newConversation)) {
                if let id = workbench.selectedProjectID { workbench.newConversation(in: id) }
            },
            PaletteCommand(id: "open", title: String(localized: "打开项目…"), icon: "folder-plus", shortcut: key(.openWorkspace)) {
                if let url = WorkspaceStore.chooseDirectory() { AppActions.shared.openWorkspace(url) }
            },
            PaletteCommand(id: "quickOpen", title: String(localized: "快速打开文件"), icon: "file-search", shortcut: key(.quickOpen)) {
                PaletteModel.shared.present(.files, workbench: workbench)
            },
            PaletteCommand(id: "search", title: String(localized: "在文件中搜索"), icon: "text-search", shortcut: key(.globalSearch)) {
                workbench.showRight(.search); SearchModel.shared.requestFocus()
            },
            PaletteCommand(id: "save", title: String(localized: "保存文件"), icon: "save", shortcut: key(.saveFile)) { AppActions.shared.saveActiveFile() },
            PaletteCommand(id: "saveAll", title: String(localized: "保存全部文件"), icon: "save", shortcut: nil) { AppActions.shared.saveAllFiles() },
            PaletteCommand(id: "gitHistory", title: String(localized: "显示 Git 历史"), icon: "git-graph", shortcut: nil) {
                if let id = workbench.selectedProjectID { workbench.openHistory(project: id) }
            },
            PaletteCommand(id: "fileHistory", title: String(localized: "查看当前文件的 Git 历史"), icon: "clock", shortcut: nil) {
                if let id = workbench.selectedProjectID, case .file(let path)? = workbench.dock.focusedGroup?.active?.kind { workbench.openHistory(project: id, path: path) }
            },
            PaletteCommand(id: "fileBlame", title: String(localized: "查看当前文件的 Git Blame"), icon: "user", shortcut: nil) {
                if case .file(let path)? = workbench.dock.focusedGroup?.active?.kind { workbench.openBlame(path) }
            },
            PaletteCommand(id: "terminal", title: String(localized: "新建终端标签"), icon: "square-terminal", shortcut: key(.newTerminal)) { AppActions.shared.openTerminal() },
            PaletteCommand(id: "explorer", title: String(localized: "显示文件资源管理器"), icon: "folder", shortcut: nil) { workbench.showRight(.files) },
            PaletteCommand(id: "gitPane", title: String(localized: "显示 Git"), icon: "git-branch", shortcut: nil) { workbench.showRight(.git) },
            PaletteCommand(id: "changesTab", title: String(localized: "在标签中查看本轮改动"), icon: "file-diff", shortcut: nil) {
                if let id = workbench.selectedProjectID { workbench.openChanges(project: id) }
            },
            PaletteCommand(id: "left", title: workbench.layout.leftVisible ? String(localized: "隐藏左栏") : String(localized: "显示左栏"), icon: "panel-left", shortcut: key(.toggleSidebar)) { workbench.toggleLeft() },
            PaletteCommand(id: "right", title: workbench.layout.rightVisible ? String(localized: "隐藏右栏") : String(localized: "显示右栏"), icon: "panel-right", shortcut: key(.toggleInspector)) { workbench.toggleRight() },
            PaletteCommand(id: "bottom", title: workbench.layout.bottomVisible ? String(localized: "隐藏底部面板") : String(localized: "显示底部面板"), icon: "panel-bottom", shortcut: key(.togglePanel)) { workbench.toggleBottom() },
            PaletteCommand(id: "settings", title: String(localized: "设置…"), icon: "settings", shortcut: "⌘,") { AppActions.shared.openSettings() },
            PaletteCommand(id: "tools", title: String(localized: "工具与扩展…"), icon: "puzzle", shortcut: key(.extensions)) { AppActions.shared.openSettings(page: .tools) },
            PaletteCommand(id: "shortcuts", title: String(localized: "快捷键设置"), icon: "keyboard", shortcut: nil) { AppActions.shared.openSettings(page: .shortcuts) },
        ]
    }
}

/// 面板视图:覆盖在工作台顶部居中。
struct PaletteOverlay: View {
    let workbench: WorkbenchModel
    @Bindable private var palette = PaletteModel.shared
    @FocusState private var focused: Bool

    var body: some View {
        if palette.isPresented {
            let items = palette.items(workbench: workbench)
            ZStack(alignment: .top) {
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .onTapGesture { palette.dismiss() }
                card(items)
                    .padding(.top, 70)
            }
            .onChange(of: palette.mode) { focused = true }
        }
    }

    private func card(_ items: [PaletteItem]) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image.om(palette.mode == .files ? "file-search" : "command", size: 14).foregroundStyle(OMColors.secondaryText)
                TextField(palette.mode == .files ? "按文件名搜索(输入 > 执行命令)" : "输入命令", text: $palette.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($focused)
                    .onSubmit { run(items) }
                    .onKeyPress(.downArrow) { palette.selection = min(palette.selection + 1, max(items.count - 1, 0)); return .handled }
                    .onKeyPress(.upArrow) { palette.selection = max(palette.selection - 1, 0); return .handled }
                    .onKeyPress(.escape) { palette.dismiss(); return .handled }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            Divider()
            if items.isEmpty {
                Text(palette.mode == .files && WorkspaceIndexModel.shared.isLoading ? "正在建立文件索引…" : "没有匹配项")
                    .font(OMFonts.small).foregroundStyle(OMColors.secondaryText).padding(16)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                PaletteRow(item: item, selected: index == palette.selection)
                                    .id(item.id)
                                    .onTapGesture { palette.selection = index; run(items) }
                                    .accessibilityElement(children: .combine)
                                    .accessibilityAddTraits(index == palette.selection ? [.isButton, .isSelected] : .isButton)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .frame(height: min(CGFloat(items.count) * 29 + 8, 340))
                    .onChange(of: palette.selection) { _, new in
                        if items.indices.contains(new) { proxy.scrollTo(items[new].id) }
                    }
                }
            }
        }
        .frame(width: 580)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(OMColors.hairline))
        .shadow(color: .black.opacity(0.25), radius: 24, y: 8)
        .onAppear { focused = true }
    }

    private func run(_ items: [PaletteItem]) {
        guard items.indices.contains(palette.selection) else { return }
        let item = items[palette.selection]
        palette.dismiss()
        item.run()
    }
}

private struct PaletteRow: View {
    let item: PaletteItem
    let selected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image.om(item.icon, size: 13).foregroundStyle(OMColors.secondaryText).frame(width: 18)
            Text(titleText).font(.system(size: 13)).lineLimit(1)
            if let subtitle = item.subtitle {
                Text(subtitle).font(OMFonts.caption).foregroundStyle(OMColors.secondaryText).lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: 8)
            if let trailing = item.trailing {
                Text(trailing).font(OMFonts.caption).foregroundStyle(OMColors.secondaryText)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? OMColors.accent.opacity(0.22) : .clear).padding(.horizontal, 4))
        .contentShape(Rectangle())
    }

    /// 标题,匹配到的字符加粗并着色。
    private var titleText: AttributedString {
        var text = AttributedString(item.title)
        guard !item.positions.isEmpty else { return text }
        let chars = Array(item.title)
        var cursor = text.startIndex
        for (i, _) in chars.enumerated() {
            let next = text.index(afterCharacter: cursor)
            if item.positions.contains(i) {
                text[cursor..<next].font = .system(size: 13, weight: .bold)
                text[cursor..<next].foregroundColor = OMColors.accent
            }
            cursor = next
        }
        return text
    }
}
