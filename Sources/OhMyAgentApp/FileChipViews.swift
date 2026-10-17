// @author ixxxxoooo
// 输入框里的文件/文件夹提及 chip:彩色文件类型图标 + 文件名,悬停显示移除按钮,点击文件在编辑器打开。

import ChatKit
import DesignSystem
import IconKit
import SwiftUI

/// 单个文件提及 chip。
struct FileMentionChip: View {
    let mention: FileMention
    /// 点击右侧 × 的回调;为 nil 时不显示移除按钮(输入框内联 chip 用退格整颗删除)
    var onRemove: (() -> Void)?
    /// 内联在文字里时使用更矮的高度
    var compact = false
    /// 移除按钮仅在悬停时出现(输入框内联 chip 用;位置始终预留,避免悬停时 chip 宽度跳动)
    var removeOnHover = false
    @State private var hovering = false

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: compact ? OMRadius.tag : OMRadius.control, style: .continuous) }

    var body: some View {
        HStack(spacing: 5) {
            OMFileIcon(name: mention.name, isDirectory: mention.isDirectory, size: 14)
            nameText
            if onRemove != nil { removeButton }
        }
        .padding(.leading, 8)
        .padding(.trailing, onRemove == nil ? 8 : 4)
        .frame(height: compact ? 22 : 26)
        .background(OMColors.card, in: shape)
        .overlay(shape.strokeBorder(hovering ? OMColors.accent.opacity(0.6) : OMColors.hairline))
        .contentShape(shape)
        .onHover { hovering = $0 }
        .onTapGesture(perform: openFile)
        .omTooltip(mention.path)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: mention.isDirectory ? "文件夹" : "文件") + " " + mention.name)
    }

    private var nameText: some View {
        Text(mention.name)
            .font(OMFonts.small)
            .foregroundStyle(OMColors.primaryText)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: 180)
    }

    private var removeButton: some View {
        Button(action: { onRemove?() }) {
            Image.om("x", size: 10)
                .foregroundStyle(OMColors.secondaryText)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(removeOnHover ? (hovering ? 1 : 0) : (hovering ? 1 : 0.45))
        .omTooltip("移除引用")
        .accessibilityLabel("移除引用")
    }

    /// 点击文件 chip 在编辑器打开(文件夹不处理)。
    private func openFile() {
        guard !mention.isDirectory else { return }
        _ = AppEnvironment.shared.workbench.openFile(mention.path, preview: true)
    }
}
