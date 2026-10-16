// @author ixxxxoooo
// 图片预览:点击输入框或消息里的缩略图,在当前窗口以灯箱方式查看原图(对标 Cursor)。
// 支持拖动平移、触控板双指平移、滚轮/⌘+滚动/捏合缩放、双击在「适应窗口」与 100% 之间切换、Esc 关闭;
// 工具栏全部为图标:缩小、放大、适应窗口、复制、下载、关闭。

import AppKit
import ChatKit
import DesignSystem
import IconKit
import MermaidKit
import OMLog
import SwiftUI
import UniformTypeIdentifiers

/// 预览的显示状态(全局唯一一个灯箱)。
@MainActor
@Observable
final class ImagePreviewStore {
    static let shared = ImagePreviewStore()

    /// 一次展示的内容。
    struct Item {
        let id = UUID()
        let name: String
        let data: Data
        let mimeType: String
        let image: NSImage
    }

    /// 当前展示的图片;nil 表示关闭
    private(set) var item: Item?

    /// 打开预览。
    /// - Parameter attachment: 图片附件;数据无法解码时忽略
    func present(_ attachment: ImageAttachment) {
        guard let image = NSImage(data: attachment.data), image.size.width > 0, image.size.height > 0 else { return }
        item = Item(name: attachment.name, data: attachment.data, mimeType: attachment.mimeType, image: image)
    }

    /// 关闭预览。
    func dismiss() { item = nil }
}

/// 灯箱覆盖层:放在工作台最上层;打开时遮罩整个窗口,点击遮罩空白处关闭。
struct ImagePreviewOverlay: View {
    private let store = ImagePreviewStore.shared

    var body: some View {
        ZStack {
            if let item = store.item {
                ImagePreviewPanel(item: item) { store.dismiss() }
                    .id(item.id)
                    .transition(.opacity)
            }
        }
        .animation(omShouldReduceMotion() ? nil : .easeOut(duration: 0.15), value: store.item?.id)
    }
}

/// 灯箱本体:视口 + 顶部工具栏。
private struct ImagePreviewPanel: View {
    let item: ImagePreviewStore.Item
    let onClose: () -> Void
    @State private var viewport = MermaidViewport()
    @State private var viewSize: CGSize = .zero
    @State private var autoFit = true
    @State private var copied = false

    private var imageSize: CGSize { item.image.size }

    var body: some View {
        ZStack(alignment: .top) {
            OMColors.maskInk.opacity(0.72)
                .contentShape(Rectangle())
                .onTapGesture { onClose() }
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("关闭图片预览")
            ZStack {
                Canvas { ctx, _ in
                    let resolved = ctx.resolve(Image(nsImage: item.image))
                    let rect = CGRect(
                        x: viewport.offset.x, y: viewport.offset.y,
                        width: imageSize.width * viewport.scale, height: imageSize.height * viewport.scale
                    )
                    ctx.draw(resolved, in: rect)
                }
                MermaidInteractionLayer(
                    onPan: { delta in autoFit = false; viewport.pan(by: delta) },
                    onZoom: { factor, anchor in autoFit = false; viewport.zoom(by: factor, anchor: anchor) },
                    onDoubleClick: { toggleFit() },
                    onClose: { onClose() },
                    onClick: { point in
                        // 点在图片之外的空白处 = 关闭
                        let rect = CGRect(x: viewport.offset.x, y: viewport.offset.y, width: imageSize.width * viewport.scale, height: imageSize.height * viewport.scale)
                        if !rect.contains(point) { onClose() }
                    }
                )
            }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                viewSize = size
                if autoFit { fit() }
            }
            toolbar
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("图片预览")
    }

    // MARK: 工具栏

    private var toolbar: some View {
        HStack(spacing: 2) {
            Text(item.name).font(OMFonts.small).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                .frame(maxWidth: 220, alignment: .leading).padding(.leading, 8)
            Divider().frame(height: 14).padding(.horizontal, 4)
            FloatingIconButton(icon: "zoom-out", help: "缩小") { zoom(1 / 1.25) }
            Text(viewport.percentText).font(OMFonts.caption).monospacedDigit().foregroundStyle(.white.opacity(0.85))
                .frame(minWidth: 40)
            FloatingIconButton(icon: "zoom-in", help: "放大") { zoom(1.25) }
            FloatingIconButton(icon: "scan", help: "适应窗口") { autoFit = true; fit() }
            Divider().frame(height: 14).padding(.horizontal, 4)
            FloatingIconButton(icon: copied ? "check" : "copy", help: "复制图片", active: copied) { copy() }
            FloatingIconButton(icon: "download", help: "下载") { save() }
            FloatingIconButton(icon: "x", help: "关闭") { onClose() }
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(OMColors.onAccent.opacity(0.12)))
        .padding(.top, 14)
    }

    // MARK: 操作

    private func fit() { viewport.fit(scene: imageSize, in: viewSize, padding: 56, maxFit: 1) }

    private func toggleFit() {
        if autoFit || abs(viewport.scale - 1) > 0.01 {
            autoFit = false
            viewport.actualSize(scene: imageSize, in: viewSize)
        } else {
            autoFit = true
            fit()
        }
    }

    private func zoom(_ factor: Double) {
        autoFit = false
        viewport.zoom(by: factor, anchor: CGPoint(x: viewSize.width / 2, y: viewSize.height / 2))
    }

    /// 复制图片(同时放入 PNG 与 TIFF 以兼容各应用)。
    private func copy() {
        let board = NSPasteboard.general
        board.clearContents()
        board.writeObjects([item.image])
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            copied = false
        }
    }

    /// 另存为:写盘在后台线程。
    private func save() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = ImagePreviewNaming.suggestedName(item.name, mimeType: item.mimeType)
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let data = item.data
        Task.detached(priority: .userInitiated) {
            do { try data.write(to: url, options: .atomic) } catch {
                Log.ui.error("保存图片失败:\(url.lastPathComponent) \(error.localizedDescription)")
            }
        }
    }
}

/// 保存文件名建议(纯函数,便于测试)。
enum ImagePreviewNaming {
    /// 为图片生成带正确扩展名的文件名。
    /// - Parameters:
    ///   - name: 显示名(可能是「粘贴的图片」等不带扩展名的名字)
    ///   - mimeType: MIME 类型
    /// - Returns: 如 `截图.png`;已有匹配扩展名时保持原样
    static func suggestedName(_ name: String, mimeType: String) -> String {
        let ext = UTType(mimeType: mimeType)?.preferredFilenameExtension ?? "png"
        let base = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let safe = (base.isEmpty ? String(localized: "图片") : base).replacingOccurrences(of: "/", with: "-")
        let current = (safe as NSString).pathExtension.lowercased()
        if current == ext || (ext == "jpeg" && current == "jpg") { return safe }
        return (safe as NSString).deletingPathExtension.isEmpty ? "\(safe).\(ext)" : "\((safe as NSString).deletingPathExtension).\(ext)"
    }
}
