// @author ixxxxoooo
// Mermaid 图表的导出与复制:PNG(位图)、PDF(矢量)、源码(.mmd);复制图片时同时放入源码文本。
// 聊天内的图块与悬浮预览共用,避免两处各写一套。

import AppKit
import MermaidKit
import OMLog
import UniformTypeIdentifiers

/// 导出格式。
enum MermaidExportFormat: CaseIterable {
    case png, pdf, source

    /// 菜单标题(不含图标,图标按钮的下拉里使用)。
    var title: String {
        switch self {
        case .png: return String(localized: "下载 PNG 图片")
        case .pdf: return String(localized: "下载 PDF 矢量图")
        case .source: return String(localized: "下载 Mermaid 源码")
        }
    }

    var fileExtension: String {
        switch self {
        case .png: return "png"
        case .pdf: return "pdf"
        case .source: return "mmd"
        }
    }

    var contentType: UTType {
        switch self {
        case .png: return .png
        case .pdf: return .pdf
        case .source: return UTType(filenameExtension: "mmd") ?? .plainText
        }
    }
}

/// 图表导出与复制。
@MainActor
enum MermaidExport {
    /// 生成指定格式的数据。
    /// - Parameters:
    ///   - format: 格式
    ///   - scene: 场景
    ///   - source: 源码
    ///   - dark: 是否深色
    /// - Returns: 数据;渲染失败为 nil
    static func data(_ format: MermaidExportFormat, scene: MScene, source: String, dark: Bool) -> Data? {
        switch format {
        case .png: return MermaidRenderer.pngData(scene, dark: dark)
        case .pdf: return MermaidRenderer.pdfData(scene, dark: dark)
        case .source: return source.data(using: .utf8)
        }
    }

    /// 弹出保存面板并写入文件(写盘在后台线程)。
    /// - Parameters:
    ///   - format: 格式
    ///   - scene: 场景
    ///   - source: 源码
    ///   - dark: 是否深色
    static func save(_ format: MermaidExportFormat, scene: MScene, source: String, dark: Bool) {
        guard let data = data(format, scene: scene, source: source, dark: dark) else {
            Log.ui.warning("Mermaid 导出失败:渲染为空", ["format": format.fileExtension])
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.contentType]
        panel.nameFieldStringValue = "mermaid.\(format.fileExtension)"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task.detached {
            do {
                try data.write(to: url, options: .atomic)
                Log.ui.info("Mermaid 已导出", ["file": url.lastPathComponent, "bytes": "\(data.count)"])
            } catch {
                Log.ui.error("Mermaid 导出写入失败", ["error": error.localizedDescription])
            }
        }
    }

    /// 复制图片到剪贴板(同时带上源码文本:粘贴到图片应用得到图,粘贴到文本框得到源码)。
    /// - Returns: 是否成功
    @discardableResult
    static func copyImage(scene: MScene, source: String, dark: Bool) -> Bool {
        guard let png = MermaidRenderer.pngData(scene, dark: dark) else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.declareTypes([.png, .string], owner: nil)
        let imageOK = pasteboard.setData(png, forType: .png)
        let textOK = pasteboard.setString(source, forType: .string)
        return imageOK && textOK
    }

    /// 复制源码文本。
    static func copySource(_ source: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(source, forType: .string)
    }
}
