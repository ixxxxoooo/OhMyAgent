// @author ixxxxoooo
// 工具结果里的图片(浏览器截图、读取图片文件等):在详情区以限高缩略图显示,点击进入灯箱查看原图。

import ChatKit
import DesignSystem
import IconKit
import SwiftUI

/// 工具结果图片:异步解码一次,之后沿用 `AttachmentImageCache` 的解码缓存。
struct ToolImageView: View {
    /// ACP `image` 内容块里的 base64 数据
    let base64: String
    let mimeType: String
    @State private var attachment: ImageAttachment?
    @State private var failed = false
    @State private var hovering = false

    /// 缩略图的最大尺寸
    private static let maxSize = CGSize(width: 420, height: 260)

    /// 等比缩放到最大尺寸内(不放大)。
    /// - Parameter size: 图片原始尺寸
    /// - Returns: 显示尺寸
    private static func fittedSize(_ size: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return maxSize }
        let scale = min(maxSize.width / size.width, maxSize.height / size.height, 1)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    var body: some View {
        Group {
            if let attachment, let image = AttachmentImageCache.image(for: attachment) {
                Button { ImagePreviewStore.shared.present(attachment) } label: {
                    let fitted = Self.fittedSize(image.size)
                    Image(nsImage: image)
                        .resizable()
                        .frame(width: fitted.width, height: fitted.height)
                        .clipShape(RoundedRectangle(cornerRadius: OMRadius.control))
                        .overlay(RoundedRectangle(cornerRadius: OMRadius.control).strokeBorder(hovering ? OMColors.accent.opacity(0.6) : OMColors.hairline))
                        .contentShape(RoundedRectangle(cornerRadius: OMRadius.control))
                }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
                .omTooltip("点击查看原图")
                .accessibilityLabel("图片")
                .accessibilityHint("查看原图")
            } else if failed {
                Label("[图片]", om: "image")
                    .font(OMFonts.small)
                    .foregroundStyle(OMColors.secondaryText)
            } else {
                OMSpinner(.mini)
            }
        }
        .task(id: base64.count) {
            let data = base64
            let type = mimeType
            let decoded = await Task.detached(priority: .utility) { () -> ImageAttachment? in
                guard let bytes = Data(base64Encoded: data), !bytes.isEmpty else { return nil }
                return ImageAttachment(data: bytes, mimeType: type, name: String(localized: "图片"))
            }.value
            attachment = decoded
            failed = decoded == nil
        }
    }
}
