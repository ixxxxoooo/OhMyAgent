// @author ixxxxoooo
// 项目图标:侧栏里的图标渲染(默认文件夹 / Lucide / 表情 / 图片)与「更换图标」对话框。

import AppKit
import ChatKit
import DesignSystem
import IconKit
import ImageIO
import SwiftUI
import WorkbenchKit

/// 图片图标的缩略图缓存(按文件名;文件名是随机 UUID,内容不会原地变化)。
@MainActor
private enum ProjectImageCache {
    private static var images: [String: NSImage] = [:]

    /// 读取并缩略(最长边 64 像素)。
    static func image(at url: URL) -> NSImage? {
        if let cached = images[url.lastPathComponent] { return cached }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 64,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: 16, height: 16))
        images[url.lastPathComponent] = image
        return image
    }
}

/// 项目图标视图:固定 16×16 占位,默认是文件夹。
struct ProjectIconView: View {
    let icon: ProjectIcon?
    let directory: URL
    let expanded: Bool
    let isSelected: Bool
    var size: CGFloat = 14

    var body: some View {
        Group {
            switch icon?.kind {
            case .symbol:
                Image.om(icon?.value ?? "folder", size: size)
                    .foregroundStyle(isSelected ? OMColors.accent : OMColors.secondaryText)
                    .opacity(isSelected ? 1 : 0.8)
            case .emoji:
                Text(verbatim: icon?.value ?? "").font(OMFonts.custom(size, weight: .regular))
                    .opacity(isSelected ? 1 : 0.9)
            case .image:
                if let icon, let url = ProjectIconFiles.fileURL(for: icon, in: directory), let image = ProjectImageCache.image(at: url) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: size + 2, height: size + 2)
                        .clipShape(RoundedRectangle(cornerRadius: OMRadius.tag, style: .continuous))
                        .opacity(isSelected ? 1 : 0.9)
                } else {
                    folder
                }
            case nil:
                folder
            }
        }
        .frame(width: 16, height: 16)
        .accessibilityHidden(true)
    }

    private var folder: some View {
        Image.om(expanded ? "folder-open" : "folder", size: size)
            .opacity(isSelected ? 1 : 0.6)
            .foregroundStyle(isSelected ? OMColors.accent : OMColors.secondaryText)
    }
}

/// 「更换图标」对话框的结果。
@MainActor
@Observable
private final class ProjectIconPickResult {
    var icon: ProjectIcon?
    /// 本次对话中导入的图片(取消或被替换时需要清理)
    var imported: [ProjectIcon] = []
    init(icon: ProjectIcon?) { self.icon = icon }
}

/// 更换项目图标。
@MainActor
enum ProjectIconPicker {
    /// 弹出对话框;确认后写入项目。
    /// - Parameters:
    ///   - project: 目标项目
    ///   - workbench: 工作台模型
    static func present(project: ProjectEntry, workbench: WorkbenchModel) {
        let result = ProjectIconPickResult(icon: project.icon)
        let directory = workbench.projectIconDirectory
        let code = OMModal.run(width: 440) { handle in
            ProjectIconPickerCard(projectName: project.name, directory: directory, result: result,
                                  importImage: { workbench.importProjectIcon(imageAt: $0) }, finish: { handle.finish($0) })
        }
        if code == 0 { workbench.setProjectIcon(result.icon, for: project.id) }
        // 清理没有被采用的导入图片
        for item in result.imported where item != (code == 0 ? result.icon : nil) {
            ProjectIconFiles.removeFile(for: item, in: directory)
        }
    }
}

/// 更换图标卡片:搜索 + 符号网格、表情、图片、恢复默认。
private struct ProjectIconPickerCard: View {
    let projectName: String
    let directory: URL
    @Bindable var result: ProjectIconPickResult
    let importImage: (URL) -> ProjectIcon?
    let finish: (Int) -> Void
    @State private var query = ""
    @State private var emojiText = ""
    @FocusState private var searchFocused: Bool

    private static let emojis = ["📁", "🚀", "🧪", "🛠️", "📦", "🎯", "💡", "🔥", "⭐️", "🌱", "🧠", "🤖", "🎨", "📚", "🔒", "🌐", "🍎", "🐍", "☕️", "🦀", "🐳", "⚡️", "🧩", "🏗️"]
    private static let allSymbols = IconCatalog.bundledNames.sorted()

    private var symbols: [String] {
        let key = query.trimmingCharacters(in: .whitespaces).lowercased()
        return key.isEmpty ? Self.allSymbols : Self.allSymbols.filter { $0.contains(key) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ProjectIconView(icon: result.icon, directory: directory, expanded: false, isSelected: true, size: 20)
                    .frame(width: 28, height: 28)
                    .background(OMColors.subtleFill, in: RoundedRectangle(cornerRadius: OMRadius.control, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text("更换图标").font(OMFonts.title).foregroundStyle(OMColors.primaryText)
                    Text(verbatim: projectName).font(OMFonts.small).foregroundStyle(OMColors.secondaryText).lineLimit(1)
                }
            }
            HStack(spacing: 6) {
                Image.om("search", size: 12).foregroundStyle(OMColors.tertiaryText)
                TextField("搜索图标", text: $query)
                    .textFieldStyle(.plain).font(OMFonts.small).focused($searchFocused)
                    .accessibilityLabel("搜索图标")
            }
            .padding(.horizontal, 8).frame(height: 28)
            .background(OMColors.subtleFill, in: RoundedRectangle(cornerRadius: OMRadius.control, style: .continuous))

            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(36), spacing: 4), count: 10), spacing: 4) {
                    ForEach(symbols, id: \.self) { name in
                        let selected = result.icon == ProjectIcon(kind: .symbol, value: name)
                        Button { result.icon = ProjectIcon(kind: .symbol, value: name) } label: {
                            Image.om(name, size: 15).foregroundStyle(OMColors.primaryText).frame(width: 36, height: 32).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(selected ? OMColors.selectedFill : Color.clear, in: RoundedRectangle(cornerRadius: OMRadius.tag, style: .continuous))
                        .help(name)
                        .accessibilityLabel(name)
                    }
                }
                if symbols.isEmpty {
                    Text("没有匹配的图标").font(OMFonts.small).foregroundStyle(OMColors.secondaryText).padding(12)
                }
            }
            .frame(height: 156)

            VStack(alignment: .leading, spacing: 6) {
                Text("表情").font(OMFonts.caption).foregroundStyle(OMColors.tertiaryText)
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 4), count: 12), spacing: 4) {
                    ForEach(Self.emojis, id: \.self) { emoji in
                        let selected = result.icon == ProjectIcon(kind: .emoji, value: emoji)
                        Button { result.icon = ProjectIcon.emoji(emoji) } label: {
                            Text(verbatim: emoji).font(OMFonts.custom(15, weight: .regular)).frame(width: 30, height: 28).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(selected ? OMColors.selectedFill : Color.clear, in: RoundedRectangle(cornerRadius: OMRadius.tag, style: .continuous))
                        .accessibilityLabel(emoji)
                    }
                }
                HStack(spacing: 6) {
                    TextField("输入任意表情", text: $emojiText)
                        .textFieldStyle(.plain).font(OMFonts.small)
                        .padding(.horizontal, 8).frame(height: 26)
                        .background(OMColors.subtleFill, in: RoundedRectangle(cornerRadius: OMRadius.control, style: .continuous))
                        .onChange(of: emojiText) { _, text in
                            if let icon = ProjectIcon.emoji(text) { result.icon = icon }
                        }
                        .accessibilityLabel("输入任意表情")
                    Button("选择图片…") { chooseImage() }.buttonStyle(.omSecondary)
                    Button("恢复默认") { result.icon = nil }.buttonStyle(.omSecondary).disabled(result.icon == nil)
                }
            }

            HStack(spacing: 8) {
                Button("取消") { finish(-1) }.buttonStyle(OMButtonStyle(.secondary, size: .regular))
                Spacer()
                Button("完成") { finish(0) }
                    .buttonStyle(OMButtonStyle(.primary, size: .regular))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .task {
            try? await Task.sleep(for: .milliseconds(40))
            searchFocused = true
        }
    }

    /// 选择图片文件并导入。
    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        panel.prompt = String(localized: "选择")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let icon = importImage(url) {
            result.imported.append(icon)
            result.icon = icon
        } else {
            OMDialog.alert(title: String(localized: "无法使用这张图片"), message: String(localized: "请选择 10 MB 以内的 PNG、JPEG、GIF、HEIC、TIFF 或 WebP 图片。"), isError: true)
        }
    }
}
