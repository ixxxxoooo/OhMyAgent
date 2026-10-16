// @author ixxxxoooo
// 文件标签页顶部的面包屑工具条(参考 kuku 的 FileViewer 与 Cursor 的 breadcrumbs):
// 左侧是相对项目根的路径(目录弱化、文件名突出),右侧依次是显示模式切换(仅可渲染的类型)、在 Finder 中显示、复制内容。

import DesignSystem
import IconKit
import SwiftUI
import WorkbenchKit

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
    /// 在面包屑下拉里点选文件时打开
    var onOpen: (String) -> Void = { _ in }
    /// 是否正在「对比 HEAD」;`onToggleCompare` 为 nil 时不显示该按钮
    var isComparing = false
    var onToggleCompare: (() -> Void)?

    @State private var copied = false
    /// 当前展开下拉的面包屑段(绝对路径)
    @State private var openedSegment: String?

    var body: some View {
        HStack(spacing: 10) {
            breadcrumb
            Spacer(minLength: 8)
            if modes.count > 1 { ModeSwitch(modes: modes, mode: mode, onMode: onMode) }
            if let onToggleCompare {
                HeaderIconButton(icon: "file-diff", help: isComparing ? "返回编辑器" : "对比 HEAD(Git 差异)", tint: isComparing ? OMColors.accent : nil, action: onToggleCompare)
            }
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

    private var segments: [FileBreadcrumb.Segment] { FileBreadcrumb.segments(path: path, root: projectRoot) }

    /// 每一段都是按钮:点击弹出同级文件与目录(对标 Cursor/VS Code 的面包屑)。
    private var breadcrumb: some View {
        HStack(spacing: 0) {
            ForEach(Array(segments.enumerated()), id: \.element.path) { index, segment in
                let isLast = index == segments.count - 1
                if index > 0 { Text("›").foregroundStyle(OMColors.tertiaryText).padding(.horizontal, 3) }
                BreadcrumbButton(
                    segment: segment, isLast: isLast,
                    isOpen: Binding(get: { openedSegment == segment.path }, set: { openedSegment = $0 ? segment.path : nil }),
                    onOpen: { target in openedSegment = nil; onOpen(target) }
                )
                .layoutPriority(isLast ? 1 : 0)
            }
        }
        .font(OMFonts.monoSmall)
        .help(path)
        .accessibilityElement(children: .contain)
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

/// 面包屑的一段:点击展开其所在目录的同级项。
private struct BreadcrumbButton: View {
    let segment: FileBreadcrumb.Segment
    let isLast: Bool
    @Binding var isOpen: Bool
    let onOpen: (String) -> Void
    @State private var hovering = false

    var body: some View {
        Button { isOpen.toggle() } label: {
            Text(segment.name)
                .foregroundStyle(isLast ? Color.primary : OMColors.secondaryText)
                .lineLimit(1).truncationMode(isLast ? .middle : .head)
                .padding(.horizontal, 4)
                .frame(height: 20)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(hovering || isOpen ? Color.primary.opacity(0.07) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            BreadcrumbMenu(startDirectory: segment.parentDirectory, current: segment.path, onOpen: onOpen)
        }
        .accessibilityLabel(segment.name)
        .accessibilityHint(String(localized: "显示同级文件"))
    }
}

/// 面包屑下拉:列出目录内容;点目录进入,点文件打开,当前项打勾,顶部「返回」回到上一级。
private struct BreadcrumbMenu: View {
    let startDirectory: String
    let current: String
    let onOpen: (String) -> Void
    @State private var directory: String
    @State private var entries: [FileEntry] = []

    init(startDirectory: String, current: String, onOpen: @escaping (String) -> Void) {
        self.startDirectory = startDirectory
        self.current = current
        self.onOpen = onOpen
        _directory = State(initialValue: startDirectory)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if directory != startDirectory {
                Button { directory = (directory as NSString).deletingLastPathComponent } label: {
                    HStack(spacing: 6) {
                        Image.om("chevron-left", size: 11)
                        Text((directory as NSString).lastPathComponent).font(OMFonts.small).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10).frame(height: 26).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("返回上一级")
                Divider()
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(entries) { entry in
                        BreadcrumbRow(entry: entry, isCurrent: entry.path == current) {
                            if entry.isDirectory { directory = entry.path } else { onOpen(entry.path) }
                        }
                    }
                    if entries.isEmpty { Text("空文件夹").font(OMFonts.small).foregroundStyle(OMColors.secondaryText).padding(10) }
                }
                .padding(4)
            }
        }
        .frame(width: 260, height: min(max(CGFloat(entries.count), 1) * 24 + 16 + (directory != startDirectory ? 27 : 0), 340))
        .task(id: directory) {
            let target = directory
            entries = await Task.detached(priority: .userInitiated) { WorkspaceFiles.list(directory: target) }.value
        }
    }
}

private struct BreadcrumbRow: View {
    let entry: FileEntry
    let isCurrent: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                OMFileIcon(name: entry.name, isDirectory: entry.isDirectory, expanded: false, size: 15)
                Text(entry.name).font(OMFonts.small).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                if isCurrent { Image.om("check", size: 11).foregroundStyle(OMColors.accent) }
                else if entry.isDirectory { Image.om("chevron-right", size: 10).foregroundStyle(OMColors.tertiaryText) }
            }
            .padding(.horizontal, 8).frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(hovering ? Color.primary.opacity(0.08) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// 面包屑路径处理(纯函数,便于测试)。
enum FileBreadcrumb {
    /// 面包屑的一段。
    struct Segment: Equatable {
        /// 显示名
        let name: String
        /// 该段对应的绝对路径(目录或文件)
        let path: String

        /// 该段所在的目录:下拉列出它的内容。
        var parentDirectory: String { (path as NSString).deletingLastPathComponent }
    }

    /// 把文件路径拆成逐级的面包屑段。项目内从项目根的下一级开始;项目外从 `~` 或 `/` 开始。
    /// - Parameters:
    ///   - path: 文件绝对路径
    ///   - root: 项目根目录绝对路径
    /// - Returns: 从外到内的段;末段为文件本身
    static func segments(path: String, root: String) -> [Segment] {
        let base = root.hasSuffix("/") ? String(root.dropLast()) : root
        var prefix: String
        var rest: String
        if !base.isEmpty, path.hasPrefix(base + "/") {
            prefix = base
            rest = String(path.dropFirst(base.count + 1))
        } else {
            prefix = ""
            rest = String(path.dropFirst(path.hasPrefix("/") ? 1 : 0))
        }
        var result: [Segment] = []
        for part in rest.split(separator: "/", omittingEmptySubsequences: true) {
            prefix += "/" + part
            result.append(Segment(name: String(part), path: prefix))
        }
        return result
    }

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
