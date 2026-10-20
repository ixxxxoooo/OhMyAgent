// @author ixxxxoooo
// 文件标签页顶部的面包屑工具条(参考 kuku 的 FileViewer 与 Cursor 的 breadcrumbs):
// 左侧是相对项目根的路径(目录弱化、文件名突出),右侧依次是显示模式切换(仅可渲染的类型)、在 Finder 中显示、复制内容。

import ChatKit
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
            if modes.count > 2 {
                // 三态(Markdown):所见即所得 / 源码 / 阅读
                OMCompactSegmented(options: modes.map { (value: $0, title: $0.title) }, selection: mode, accessibilityName: String(localized: "显示模式"), onSelect: onMode)
            } else if modes.count > 1 {
                HeaderIconButton(icon: mode.toggleIcon, help: mode == .preview ? "切换到源码" : "切换到预览", tint: nil) { onMode(mode.other) }
            }
            if let onToggleCompare {
                HeaderIconButton(icon: "file-diff", help: isComparing ? "返回编辑器" : "对比 HEAD(Git 差异)", tint: isComparing ? OMColors.accent : nil, action: onToggleCompare)
            }
            iconButton(copied ? "check" : "copy", help: copied ? "已复制" : "复制内容", tint: copied ? OMColors.success : nil) { copy() }
            iconButton("folder-open", help: "在 Finder 中显示") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 30)
        // 与内容区同色(OMColors.surface),不再画底部分隔线
        .background(OMColors.surface)
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
        .omTooltip(path)
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
                .foregroundStyle(tint ?? (hovering ? OMColors.primaryText : OMColors.secondaryText))
                .frame(width: 24, height: 22)
                .background(RoundedRectangle(cornerRadius: OMRadius.tag, style: .continuous).fill(hovering ? OMColors.hoverFill : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .omTooltip(help)
        .accessibilityLabel(help)
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
                .foregroundStyle(isLast ? OMColors.primaryText : OMColors.secondaryText)
                .lineLimit(1).truncationMode(isLast ? .middle : .head)
                .padding(.horizontal, 4)
                .frame(height: 20)
                .background(RoundedRectangle(cornerRadius: OMRadius.tag, style: .continuous).fill(hovering || isOpen ? OMColors.hoverFill : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .omCustomPicker(isPresented: $isOpen, placement: .below, width: 280) {
            BreadcrumbMenu(startDirectory: segment.parentDirectory, current: segment.path, onOpen: { path in
                isOpen = false
                onOpen(path)
            }, onDismiss: { isOpen = false })
        }
        .accessibilityLabel(segment.name)
        .accessibilityHint(String(localized: "显示同级文件"))
    }
}

/// 面包屑下拉的一项:目录/文件,或顶部的「返回上一级」。
private struct CrumbItem: PickListItem {
    var id: String
    var name: String
    var isDirectory: Bool
    var isBack = false

    var searchText: String { name }
}

/// 面包屑下拉:列出目录内容并支持搜索;点目录(或回车)进入,点文件打开,当前项打勾,顶部「返回」回到上一级;↑↓ 切换、Esc 关闭。
private struct BreadcrumbMenu: View {
    let startDirectory: String
    let current: String
    let onOpen: (String) -> Void
    let onDismiss: () -> Void
    @State private var directory: String
    @State private var entries: [FileEntry] = []
    @State private var loaded = false

    init(startDirectory: String, current: String, onOpen: @escaping (String) -> Void, onDismiss: @escaping () -> Void) {
        self.startDirectory = startDirectory
        self.current = current
        self.onOpen = onOpen
        self.onDismiss = onDismiss
        _directory = State(initialValue: startDirectory)
    }

    private var items: [CrumbItem] {
        var result: [CrumbItem] = []
        if directory != startDirectory {
            result.append(CrumbItem(id: "..", name: String(localized: "返回上一级"), isDirectory: true, isBack: true))
        }
        result += entries.map { CrumbItem(id: $0.path, name: $0.name, isDirectory: $0.isDirectory) }
        return result
    }

    var body: some View {
        PickListContent(
            items: items, selectedID: current, placeholder: String(localized: "搜索当前目录"), maxListHeight: 320,
            emptyText: loaded ? String(localized: "空文件夹") : String(localized: "正在读取…"),
            row: { item in
                HStack(spacing: 6) {
                    if item.isBack { Image.om("chevron-left", size: 12).foregroundStyle(OMColors.secondaryText).frame(width: 15) }
                    else { OMFileIcon(name: item.name, isDirectory: item.isDirectory, expanded: false, size: 15) }
                    Text(item.name).font(OMFonts.small).lineLimit(1).truncationMode(.middle)
                    if item.isDirectory, !item.isBack { Image.om("chevron-right", size: 10).foregroundStyle(OMColors.tertiaryText) }
                }
            },
            onSelect: { item in
                if item.isBack { directory = (directory as NSString).deletingLastPathComponent }
                else if item.isDirectory { directory = item.id }
                else { onOpen(item.id) }
            },
            onDismiss: onDismiss
        )
        .id("\(directory)|\(loaded)")
        .task(id: directory) {
            let target = directory
            loaded = false
            entries = await Task.detached(priority: .userInitiated) { WorkspaceFiles.list(directory: target) }.value
            loaded = true
        }
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
