// @author ygw
// 文件标签页顶部的面包屑工具条(参考 kuku 的 FileViewer 与 Cursor 的 breadcrumbs):
// 左侧是相对项目根的路径(目录弱化、文件名突出),右侧依次是显示模式切换(仅可渲染的类型)、在 Finder 中显示、复制内容。

import DesignSystem
import IconKit
import SwiftUI

/// 文件面包屑工具条。
struct FileHeaderBar: View {
    /// 文件绝对路径
    let path: String
    /// 项目根目录绝对路径(用于显示相对路径)
    let projectRoot: String
    /// 该文件可用的显示模式;为空表示没有模式可切换
    let modes: [FileViewMode]
    let mode: FileViewMode
    let onMode: (FileViewMode) -> Void
    /// 读取当前文档文本(复制用);无内容返回 nil
    let currentText: () -> String?

    @State private var copied = false

    var body: some View {
        HStack(spacing: 10) {
            breadcrumb
            Spacer(minLength: 8)
            if modes.count > 1 { ModeSwitch(modes: modes, mode: mode, onMode: onMode) }
            iconButton(copied ? "check" : "copy", help: copied ? "已复制" : "复制内容", tint: copied ? Color.green : nil) { copy() }
            iconButton("folder-open", help: "在 Finder 中显示") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 30)
        .overlay(alignment: .bottom) { Rectangle().fill(OMColors.hairline.opacity(0.6)).frame(height: 0.5) }
    }

    // MARK: 面包屑

    /// 相对项目根的路径分段;不在项目内时回退为 `~` 缩写的绝对路径。
    private var segments: (dir: String, name: String) {
        let relative = FileBreadcrumb.relativePath(path, root: projectRoot)
        let parts = relative.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        let name = parts.last ?? relative
        let dir = parts.dropLast().joined(separator: " / ")
        return (dir, name)
    }

    private var breadcrumb: some View {
        let parts = segments
        return HStack(spacing: 0) {
            if !parts.dir.isEmpty {
                Text(parts.dir + " / ")
                    .foregroundStyle(OMColors.secondaryText)
                    .lineLimit(1).truncationMode(.head)
            }
            Text(parts.name).foregroundStyle(Color.primary).lineLimit(1).truncationMode(.middle).layoutPriority(1)
        }
        .font(OMFonts.monoSmall)
        .help(path)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "文件路径"))
        .accessibilityValue(FileBreadcrumb.relativePath(path, root: projectRoot))
    }

    // MARK: 操作

    private func copy() {
        guard let text = currentText() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }

    private func iconButton(_ icon: String, help: LocalizedStringKey, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        HeaderIconButton(icon: icon, help: help, tint: tint, action: action)
    }
}

/// 工具条图标按钮:悬停出现圆角底色。
private struct HeaderIconButton: View {
    let icon: String
    let help: LocalizedStringKey
    let tint: Color?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image.om(icon, size: 13)
                .foregroundStyle(tint ?? (hovering ? Color.primary : OMColors.secondaryText))
                .frame(width: 24, height: 22)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovering ? Color.primary.opacity(0.07) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// 显示模式切换:紧凑的分段控件,选中项有轻量底色(替代系统分段控件的厚重外观)。
private struct ModeSwitch: View {
    let modes: [FileViewMode]
    let mode: FileViewMode
    let onMode: (FileViewMode) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(modes) { item in
                Button { onMode(item) } label: {
                    Text(item.title)
                        .font(OMFonts.caption)
                        .foregroundStyle(item == mode ? Color.primary : OMColors.secondaryText)
                        .padding(.horizontal, 9)
                        .frame(height: 20)
                        .background(Capsule().fill(item == mode ? Color.primary.opacity(0.1) : .clear))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(item == mode ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.primary.opacity(0.04)))
        .overlay(Capsule().strokeBorder(OMColors.hairline.opacity(0.6), lineWidth: 0.5))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "文件显示模式"))
    }
}

/// 面包屑路径处理(纯函数,便于测试)。
enum FileBreadcrumb {
    /// 取相对项目根的路径;不在项目内时返回用 `~` 缩写主目录的绝对路径。
    /// - Parameters:
    ///   - path: 文件绝对路径
    ///   - root: 项目根目录绝对路径
    static func relativePath(_ path: String, root: String) -> String {
        let base = root.hasSuffix("/") ? String(root.dropLast()) : root
        if !base.isEmpty, path.hasPrefix(base + "/") { return String(path.dropFirst(base.count + 1)) }
        return (path as NSString).abbreviatingWithTildeInPath
    }
}
