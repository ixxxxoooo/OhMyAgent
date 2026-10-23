// @author ixxxxoooo
// 资源管理器下方的「大纲」折叠区:列出活动文件的符号层级(来自语言服务器的 documentSymbol),点击跳转到定义行。
// 没有语言服务器或文件无符号时显示占位文案。

import DesignSystem
import EditorKit
import IconKit
import LSPKit
import SwiftUI

struct IDEOutlineSection: View {
    let workspace: IDEWorkspace
    @AppStorage("ide.outlineExpanded") private var expanded = true

    private var rows: [(symbol: LSPSymbol, depth: Int)] {
        guard workspace.outlinePath == workspace.model.activeFilePath else { return [] }
        return workspace.outline.flatMap { $0.flattened() }
    }

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(OMColors.hairline).frame(height: 1)
            Button { expanded.toggle() } label: {
                HStack(spacing: 4) {
                    Image.om(expanded ? "chevron-down" : "chevron-right", size: 12)
                    Text("大纲").font(OMFonts.caption)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(OMColors.secondaryText)
                .padding(.horizontal, 12)
                .frame(height: 26)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "大纲"))
            if expanded {
                let items = rows
                if items.isEmpty {
                    Text(workspace.model.activeFilePath == nil ? String(localized: "没有打开的文件") : String(localized: "没有可显示的符号"))
                        .font(OMFonts.small)
                        .foregroundStyle(OMColors.tertiaryText)
                        .frame(maxWidth: .infinity, minHeight: 48)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(items.enumerated()), id: \.offset) { _, entry in
                                OutlineRow(symbol: entry.symbol, depth: entry.depth) { jump(to: entry.symbol) }
                            }
                        }
                    }
                    .frame(height: 200)
                }
            }
        }
        .task(id: workspace.model.activeFilePath) { workspace.refreshOutline() }
    }

    private func jump(to symbol: LSPSymbol) {
        guard let path = workspace.model.activeFilePath else { return }
        // 活动编辑器已在该文件:直接转到行;否则经窗口模型打开并定位
        if EditorRouter.hasActiveEditor { EditorRouter.goToLine(symbol.line + 1, column: symbol.character + 1) }
        else { workspace.model.openFile(path, line: symbol.line + 1, preview: false) }
    }
}

private struct OutlineRow: View {
    let symbol: LSPSymbol
    let depth: Int
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image.om(symbol.kind.iconName, size: 12).foregroundStyle(OMColors.secondaryText)
                Text(symbol.name).font(OMFonts.small).foregroundStyle(OMColors.primaryText).lineLimit(1)
                if let detail = symbol.detail, !detail.isEmpty {
                    Text(detail).font(OMFonts.caption).foregroundStyle(OMColors.tertiaryText).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 12 + CGFloat(depth) * 12)
            .padding(.trailing, 8)
            .frame(height: 22)
            .background(hovering ? OMColors.hoverFill : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
