// @author ixxxxoooo
// IDE 命令面板视图:居中浮层(遮罩 + 卡片),输入框 + 结果列表;↑↓ 选择、↩ 执行、Esc 关闭。
// 外观沿用全局浮层规范(`omGlassCard`、令牌颜色/字号/圆角)。

import DesignSystem
import IconKit
import IDEKit
import SwiftUI
import WorkbenchKit

/// 面板浮层(盖在整个 IDE 外壳上,未显示时不占任何空间)。
struct IDEPaletteOverlay: View {
    let workspace: IDEWorkspace

    var body: some View {
        if workspace.palette.isPresented {
            ZStack(alignment: .top) {
                // 对齐 VS Code:面板吸附在标题栏搜索框正下方,不压暗背景,点击空白处关闭
                Color.clear
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { workspace.palette.dismiss() }
                IDEPaletteCard(workspace: workspace)
                    .padding(.top, TitlebarMetrics.height - 4)
            }
            .transition(.opacity)
        }
    }
}

private struct IDEPaletteCard: View {
    let workspace: IDEWorkspace
    @FocusState private var focused: Bool

    private var palette: IDEPaletteModel { workspace.palette }

    var body: some View {
        let items = palette.items(context: workspace.commandContext, recents: workspace.openRelativePaths)
        VStack(spacing: 0) {
            HStack(spacing: OMSpacing.sm) {
                Image.om(icon, size: 14).foregroundStyle(OMColors.secondaryText)
                TextField(placeholder, text: Bindable(palette).text)
                    .textFieldStyle(.plain)
                    .font(OMFonts.body)
                    .focused($focused)
                    .onSubmit { if items.indices.contains(palette.highlighted) { workspace.choose(items[palette.highlighted]) } }
                    .accessibilityLabel(placeholder)
            }
            .padding(.horizontal, OMSpacing.md)
            .frame(height: 40)
            Rectangle().fill(OMColors.hairline).frame(height: 1)
            list(items)
        }
        .frame(width: 600)
        .omGlassCard(cornerRadius: OMRadius.modal)
        .omFloatingShadow()
        .onAppear { focused = true }
        // 打开面板时焦点可能还在终端/编辑器(AppKit 第一响应者):等视图就位后再抢一次,确保唤醒即可直接输入
        .task(id: palette.focusToken) {
            focused = true
            try? await Task.sleep(for: .milliseconds(60))
            focused = true
        }
        .onKeyPress(.upArrow) { moveHighlight(-1, items) }
        .onKeyPress(.downArrow) { moveHighlight(1, items) }
        .onKeyPress(.escape) { palette.dismiss(); return .handled }
    }

    /// 键盘移动高亮;在主题选择器里同时实时预览(鼠标悬停不预览)。
    private func moveHighlight(_ delta: Int, _ items: [IDEPaletteItem]) -> KeyPress.Result {
        palette.move(delta, count: items.count)
        palette.previewTheme(items.indices.contains(palette.highlighted) ? items[palette.highlighted] : nil)
        return .handled
    }

    private var icon: String {
        if palette.customItems != nil { return "search" }
        switch palette.query {
        case .files: return "file-search"
        case .commands: return "terminal"
        case .line: return "hash"
        }
    }

    private var placeholder: String {
        if palette.customItems != nil { return palette.customPlaceholder }
        switch palette.query {
        case .files: return String(localized: "按文件名搜索(> 命令,: 转到行)")
        case .commands: return String(localized: "输入命令名称")
        case .line: return String(localized: "输入行号,如 :120 或 :120:8")
        }
    }

    @ViewBuilder
    private func list(_ items: [IDEPaletteItem]) -> some View {
        if items.isEmpty {
            Text(palette.customEmptyMessage ?? (palette.customItems == nil && palette.files.isEmpty && palette.query == .files("") ? String(localized: "正在建立文件索引…") : String(localized: "没有匹配项")))
                .font(OMFonts.small)
                .foregroundStyle(OMColors.tertiaryText)
                .frame(maxWidth: .infinity, minHeight: 56)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            IDEPaletteRow(item: item, highlighted: index == palette.highlighted)
                                .id(item.id)
                                .onTapGesture { workspace.choose(item) }
                                .accessibilityAddTraits(.isButton)
                                .onHover { if $0 { palette.highlighted = index } }
                        }
                    }
                    .padding(OMSpacing.xs)
                }
                .frame(maxHeight: 360)
                .onChange(of: palette.highlighted) { _, new in
                    if items.indices.contains(new) { proxy.scrollTo(items[new].id) }
                }
            }
        }
    }
}

private struct IDEPaletteRow: View {
    let item: IDEPaletteItem
    let highlighted: Bool

    var body: some View {
        HStack(spacing: OMSpacing.sm) {
            switch item {
            case .file(let match):
                let name = (match.path as NSString).lastPathComponent
                let dir = (match.path as NSString).deletingLastPathComponent
                OMFileIcon(name: name, size: 14)
                Text(name).font(OMFonts.body).foregroundStyle(OMColors.primaryText).lineLimit(1)
                if !dir.isEmpty {
                    Text(dir).font(OMFonts.small).foregroundStyle(OMColors.tertiaryText).lineLimit(1).truncationMode(.head)
                }
                Spacer(minLength: 0)
            case .command(let match):
                HStack(spacing: 0) {
                    Text(match.command.category + ": ").foregroundStyle(OMColors.tertiaryText)
                    Text(match.command.title).foregroundStyle(OMColors.primaryText)
                }
                .font(OMFonts.body)
                .lineLimit(1)
                Spacer(minLength: 0)
                if let shortcut = match.command.shortcut {
                    Text(shortcut)
                        .font(OMFonts.caption)
                        .foregroundStyle(OMColors.secondaryText)
                        .padding(.horizontal, 6)
                        .frame(height: 18)
                        .background(OMColors.subtleFill, in: OMPillShape())
                }
            case .location(let location):
                Spacer().frame(width: CGFloat(location.depth) * 12)
                Image.om(location.icon, size: 14).foregroundStyle(OMColors.secondaryText)
                Text(location.title).font(OMFonts.body).foregroundStyle(OMColors.primaryText).lineLimit(1)
                Text(location.detail).font(OMFonts.small).foregroundStyle(OMColors.tertiaryText).lineLimit(1).truncationMode(.head)
                Spacer(minLength: 0)
            case .line(let line, let column):
                Image.om("corner-down-right", size: 14).foregroundStyle(OMColors.secondaryText)
                Text(Self.lineText(line, column)).font(OMFonts.body).foregroundStyle(line == nil ? OMColors.tertiaryText : OMColors.primaryText)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, OMSpacing.sm)
        .frame(height: 28)
        .background(highlighted ? OMColors.selectedFill : .clear, in: RoundedRectangle(cornerRadius: OMRadius.control, style: .continuous))
        .contentShape(Rectangle())
    }

    private static func lineText(_ line: Int?, _ column: Int?) -> String {
        guard let line else { return String(localized: "输入行号以跳转") }
        if let column { return String(localized: "转到第 \(line) 行,第 \(column) 列") }
        return String(localized: "转到第 \(line) 行")
    }
}
