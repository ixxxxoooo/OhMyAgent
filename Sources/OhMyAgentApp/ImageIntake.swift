// @author ygw
// 图片摄取:把粘贴板/拖拽/文件选择得到的图片转成可发送的 `ImageAttachment`。
// 过大的图片会重新编码为 JPEG,避免超过 Claude 接口的单图 5 MB 限制。

import AppKit
import ChatKit
import Foundation
import UniformTypeIdentifiers

/// 图片摄取工具。
@MainActor
enum ImageIntake {
    /// 接受的图片类型。
    static let acceptedTypes: [UTType] = [.png, .jpeg, .gif, .webP, .heic, .tiff]

    /// 从粘贴板读取图片:优先文件 URL(Finder 拖拽/复制),其次直接的图片数据(截图)。
    /// - Parameter pasteboard: 粘贴板
    /// - Returns: 图片附件(无图片时为空)
    static func attachments(from pasteboard: NSPasteboard) -> [ImageAttachment] {
        var result: [ImageAttachment] = []
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        for url in urls {
            if let item = attachment(from: url) { result.append(item) }
        }
        if !result.isEmpty { return result }
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = pasteboard.data(forType: type), let item = attachment(fromData: data, name: String(localized: "粘贴的图片")) {
                return [item]
            }
        }
        return []
    }

    /// 粘贴板是否含图片(用于决定是否接管粘贴/拖拽)。
    static func hasImage(_ pasteboard: NSPasteboard) -> Bool {
        if pasteboard.canReadObject(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: acceptedTypes.map(\.identifier),
        ]) { return true }
        return pasteboard.data(forType: .png) != nil || pasteboard.data(forType: .tiff) != nil
    }

    /// 粘贴时是否应由图片接管:图片文件一律接管;只有截图类数据时,若同时带有文本(如从表格复制)则优先粘贴文本。
    static func prefersImage(_ pasteboard: NSPasteboard) -> Bool {
        guard hasImage(pasteboard) else { return false }
        let hasImageFile = pasteboard.canReadObject(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: acceptedTypes.map(\.identifier),
        ])
        if hasImageFile { return true }
        return (pasteboard.string(forType: .string) ?? "").isEmpty
    }

    /// 从拖放/粘贴的 `NSItemProvider` 异步读取图片(文件 URL 或图片数据)。
    /// - Parameter providers: 提供者
    /// - Returns: 图片附件
    static func attachments(from providers: [NSItemProvider]) async -> [ImageAttachment] {
        var result: [ImageAttachment] = []
        for provider in providers {
            if provider.canLoadObject(ofClass: URL.self), let url = await loadURL(provider), let item = attachment(from: url) {
                result.append(item)
                continue
            }
            for type in [UTType.png, .jpeg, .tiff, .gif, .webP, .heic] where provider.hasItemConformingToTypeIdentifier(type.identifier) {
                if let data = await loadData(provider, type: type), let item = attachment(fromData: data, name: String(localized: "拖入的图片"), preferredType: type) {
                    result.append(item)
                    break
                }
            }
        }
        return result
    }

    private static func loadURL(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
        }
    }

    private static func loadData(_ provider: NSItemProvider, type: UTType) async -> Data? {
        await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in continuation.resume(returning: data) }
        }
    }

    /// 从文件读取图片;不是图片或读取失败时返回 nil。
    /// - Parameter url: 文件 URL
    static func attachment(from url: URL) -> ImageAttachment? {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()), acceptedTypes.contains(where: { type.conforms(to: $0) }) else { return nil }
        // 先看大小,避免把超大文件整个读入内存
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size <= 40 * 1024 * 1024, let data = try? Data(contentsOf: url) else { return nil }
        return attachment(fromData: data, name: url.lastPathComponent, preferredType: type)
    }

    /// 由图片数据构造附件:TIFF 转 PNG;过大则缩小/压缩为 JPEG。
    /// - Parameters:
    ///   - data: 图片数据
    ///   - name: 显示名
    ///   - preferredType: 已知的类型
    static func attachment(fromData data: Data, name: String, preferredType: UTType? = nil) -> ImageAttachment? {
        var type = preferredType ?? .png
        var payload = data
        let isTIFF = data.starts(with: [0x49, 0x49, 0x2A, 0x00]) || data.starts(with: [0x4D, 0x4D, 0x00, 0x2A])
        if isTIFF || type == .tiff || type == .heic {
            guard let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) else { return nil }
            payload = png
            type = .png
        }
        if payload.count > ImageAttachment.maxBytes - 256 * 1024 {
            guard let shrunk = shrink(payload) else { return nil }
            payload = shrunk
            type = .jpeg
        }
        guard payload.count <= ImageAttachment.maxBytes, let mime = type.preferredMIMEType else { return nil }
        return ImageAttachment(data: payload, mimeType: mime, name: name)
    }

    /// 逐步降低质量与尺寸,直到小于上限。
    private static func shrink(_ data: Data) -> Data? {
        guard let rep = NSBitmapImageRep(data: data) else { return nil }
        var scale = 1.0
        while scale > 0.2 {
            let target = NSSize(width: Double(rep.pixelsWide) * scale, height: Double(rep.pixelsHigh) * scale)
            if let scaled = resized(rep, to: target),
               let jpeg = scaled.representation(using: .jpeg, properties: [.compressionFactor: 0.8]),
               jpeg.count <= ImageAttachment.maxBytes - 256 * 1024 {
                return jpeg
            }
            scale -= 0.2
        }
        return nil
    }

    private static func resized(_ rep: NSBitmapImageRep, to size: NSSize) -> NSBitmapImageRep? {
        guard size.width >= 1, size.height >= 1,
              let target = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
              ),
              let context = NSGraphicsContext(bitmapImageRep: target) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        rep.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return target
    }

    /// 弹出文件选择面板选择图片。
    /// - Returns: 选中的图片
    static func pickImages() -> [ImageAttachment] {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = acceptedTypes
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = String(localized: "选择要发送的图片")
        guard panel.runModal() == .OK else { return [] }
        return panel.urls.compactMap { attachment(from: $0) }
    }
}
