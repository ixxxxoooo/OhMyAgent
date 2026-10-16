// @author ixxxxoooo
// 输入框里的文件/文件夹提及 chip:彩色文件类型图标 + 文件名,悬停显示移除按钮,点击文件在编辑器打开。

import ChatKit
import DesignSystem
import IconKit
import SwiftUI

/// 单个文件提及 chip。
struct FileMentionChip: View {
    let mention: FileMention
    let onRemove: () -> Void
    @State private var hovering = false

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 8, style: .continuous) }

    var body: some View {
        HStack(spacing: 5) {
            OMFileIcon(name: mention.name, isDirectory: mention.isDirectory, size: 14)
            nameText
            removeButton
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .frame(height: 26)
        .background(OMColors.card, in: shape)
        .overlay(shape.strokeBorder(hovering ? OMColors.accent.opacity(0.6) : OMColors.hairline))
        .contentShape(shape)
        .onHover { hovering = $0 }
        .onTapGesture(perform: openFile)
        .help(mention.path)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: mention.isDirectory ? "文件夹" : "文件") + " " + mention.name)
    }

    private var nameText: some View {
        Text(mention.name)
            .font(OMFonts.small)
            .foregroundStyle(.primary)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: 180)
    }

    private var removeButton: some View {
        Button(action: onRemove) {
            Image.om("x", size: 10)
                .foregroundStyle(OMColors.secondaryText)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(hovering ? 1 : 0.45)
        .help("移除引用")
        .accessibilityLabel("移除引用")
    }

    /// 点击文件 chip 在编辑器打开(文件夹不处理)。
    private func openFile() {
        guard !mention.isDirectory else { return }
        _ = AppEnvironment.shared.workbench.openFile(mention.path, preview: true)
    }
}
