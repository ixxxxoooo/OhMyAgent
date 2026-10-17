// @author ixxxxoooo
// 时间线条目视图:用户、助手(Markdown)、思维面板、工具卡片、计划、提示。

import IconKit
import ACPKit
import ChatKit
import DesignSystem
import SwiftUI

/// 按类别分发条目视图。
struct TimelineEntryView: View {
    let entry: TimelineEntry

    var body: some View {
        switch entry.kind {
        case .user: UserMessageView(entry: entry)
        case .assistant: AssistantMessageView(entry: entry)
        case .thought: ThoughtView(entry: entry)
        case .tool: ToolRowView(entry: entry)
        case .plan: PlanView(entry: entry)
        case .notice: NoticeView(entry: entry)
        case .changes: ChangesSummaryView(entry: entry)
        case .planDoc: PlanDocView(entry: entry)
        case .turnSummary: TurnSummaryView(entry: entry)
        case .modelSwitch: ModelSwitchDividerView(entry: entry)
        }
    }
}

/// 模型切换分割线:两侧细线 + 居中「由 X 切换为 Y」。
struct ModelSwitchDividerView: View {
    let entry: TimelineEntry

    var body: some View {
        let from = entry.text
        let to = entry.detail ?? ""
        HStack(spacing: 10) {
            line
            HStack(spacing: 5) {
                Image.om("arrow-left-right", size: 12)
                Text("由 \(from) 切换为 \(to)")
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(OMFonts.caption)
            .foregroundStyle(OMColors.tertiaryText)
            line
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "模型由 \(from) 切换为 \(to)"))
    }

    private var line: some View {
        Rectangle().fill(OMColors.hairline).frame(height: 0.5)
    }
}

/// 回合结束语与操作栏 (对标 Cursor 图 6: 点赞、点踩、复制、Fork Chat、时间、模型信息)。
struct TurnSummaryView: View {
    let entry: TimelineEntry
    @Environment(SessionModel.self) private var model
    @State private var feedback: Int? = nil

    var body: some View {
        if let summary = entry.summary {
            HStack(spacing: 8) {
                // 点赞按钮
                Button {
                    feedback = feedback == 1 ? nil : 1
                } label: {
                    Image.om("thumbs-up", size: 12)
                        .foregroundStyle(feedback == 1 ? OMColors.accent : OMColors.tertiaryText)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .omTooltip(feedback == 1 ? "已赞" : "有帮助", icon: "thumbs-up")

                // 点踩按钮
                Button {
                    feedback = feedback == -1 ? nil : -1
                } label: {
                    Image.om("thumbs-down", size: 12)
                        .foregroundStyle(feedback == -1 ? OMColors.danger : OMColors.tertiaryText)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .omTooltip(feedback == -1 ? "已踩" : "需要改进", icon: "thumbs-down")

                // 复制按钮
                if !summary.outputText.isEmpty {
                    OMCopyButton(help: String(localized: "复制回复"), size: 12) { summary.outputText }
                }

                // Fork Chat 分叉按钮 (支持从本条回复分叉出会话)
                Button {
                    AppEnvironment.shared.workbench.forkConversation(from: model)
                } label: {
                    Image.om("git-branch", size: 12)
                        .foregroundStyle(OMColors.tertiaryText)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .omTooltip("分叉出新会话 (Fork Chat)", icon: "git-branch")

                Spacer(minLength: 4)

                // 品牌与模型、耗时元数据
                if let hint = summary.brand {
                    BrandIconView(BrandIcon.resolve(modelId: hint.modelId, providerPreset: hint.providerPreset, providerName: hint.providerName), size: 12)
                }
                Text(verbatim: summary.parts.joined(separator: "  ·  "))
                    .font(OMFonts.caption)
                    .foregroundStyle(OMColors.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(summary.copyText)
        }
    }
}

/// 用户消息:与底部输入框、吸顶卡一致的 Liquid Glass 圆角卡片(可带图片缩略图;运行中引导的消息带「引导」标记)。
/// 双击放大编辑(见 `UserMessageEditor`);为让双击生效,这里不启用文字选择,复制走右键菜单。
struct UserMessageView: View {
    let entry: TimelineEntry
    @Environment(\.stickyUser) private var sticky
    @State private var hovering = false

    var body: some View {
        if let sticky, let model = sticky.model, sticky.editing?.id == entry.id, !sticky.isEditorFloating(for: entry.id) {
            // 就地编辑:原位置展开为输入卡片(从吸顶卡发起的编辑悬浮在顶部,见 StickyUserOverlay)
            UserMessageEditor(model: model, entry: entry, maxWidth: .infinity) { sticky.finishEditing() }
                .id(entry.id)
        } else {
            messageCard
        }
    }

    private var messageCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            if entry.isSteered {
                Label("运行中引导", om: "corner-down-right")
                    .font(OMFonts.small)
                    .foregroundStyle(OMColors.secondaryText)
            }
            if !entry.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(entry.attachments) { item in
                            AttachmentThumbnail(attachment: item, size: 72)
                        }
                    }
                }
            }
            if !entry.text.isEmpty {
                Text(entry.text)
                    .font(OMFonts.reading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .padding(.trailing, 18)
        .omGlass(in: RoundedRectangle(cornerRadius: OMRadius.modal, style: .continuous))
        .overlay(alignment: .bottomTrailing) {
            if !entry.isSteered {
                Button { sticky?.beginEditing(entry, pinned: false) } label: {
                    Image.om("square-pen", size: 12).foregroundStyle(OMColors.secondaryText).frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(hovering ? 1 : 0)
                .padding(8)
                .help("放大编辑(双击)")
                .accessibilityLabel("放大编辑")
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: OMRadius.modal, style: .continuous))
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { if !entry.isSteered { sticky?.beginEditing(entry, pinned: false) } }
        .contextMenu {
            Button("复制") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.text, forType: .string)
            }
            if !entry.isSteered { Button("编辑并重新发送…") { sticky?.beginEditing(entry, pinned: false) } }
        }
        // 被吸顶卡接管时隐藏原行(保留布局,位置继续上报)
        .opacity(sticky?.target?.stickyID == entry.id && !(sticky?.editing?.id == entry.id && sticky?.editorPinned != true) ? 0 : 1)
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(chatScrollSpace)).minY } action: { sticky?.report(entry.id, minY: $0) }
        .onDisappear { sticky?.forget(entry.id) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("你:\(entry.text)")
        .accessibilityHint(entry.isSteered ? "" : String(localized: "双击放大编辑"))
    }
}

/// 图片附件缩略图(解码结果缓存,避免滚动时重复解码)。
/// 点击在灯箱中查看原图;输入框里的缩略图在悬停时于右上角出现移除按钮(对标 Cursor)。
struct AttachmentThumbnail: View {
    let attachment: ImageAttachment
    var size: CGFloat = 56
    /// 非 nil 时悬停显示右上角移除按钮
    var onRemove: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button { ImagePreviewStore.shared.present(attachment) } label: {
                Group {
                    if let image = AttachmentImageCache.image(for: attachment) {
                        Image(nsImage: image).resizable().scaledToFill()
                    } else {
                        Image.om("image", size: 18).foregroundStyle(OMColors.secondaryText)
                    }
                }
                .frame(width: size, height: size)
                .background(OMColors.card)
                .clipShape(RoundedRectangle(cornerRadius: OMRadius.control))
                .overlay(RoundedRectangle(cornerRadius: OMRadius.control).strokeBorder(hovering ? OMColors.accent.opacity(0.6) : OMColors.hairline))
                .contentShape(RoundedRectangle(cornerRadius: OMRadius.control))
            }
            .buttonStyle(.plain)
            .help("点击查看原图")
            .accessibilityLabel("图片 \(attachment.name)")
            .accessibilityHint("查看原图")
            if let onRemove, hovering {
                // 按图片右上角的明暗自动取反色:浅色图配深色按钮、深色图配浅色按钮,并带描边与投影,任何背景上都看得清
                let onLight = AttachmentImageCache.isLightAtTopRight(attachment)
                let fill = onLight ? OMColors.maskInk.opacity(0.82) : OMColors.onAccent.opacity(0.95)
                let glyph = onLight ? OMColors.onAccent : OMColors.maskInk
                Button(action: onRemove) {
                    Image.om("x", size: 9, weight: .bold)
                        .foregroundStyle(glyph)
                        .frame(width: 17, height: 17)
                        .background(fill, in: Circle())
                        .overlay(Circle().strokeBorder(glyph.opacity(0.55), lineWidth: 1))
                        .shadow(color: OMColors.shadowInk.opacity(0.35), radius: 2, y: 0.5)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .padding(3)
                .help("移除图片")
                .accessibilityLabel("移除图片")
                .transition(.opacity)
            }
        }
        .onHover { hovering = $0 }
    }
}

/// 缩略图解码缓存。
@MainActor
enum AttachmentImageCache {
    private static let cache = NSCache<NSUUID, NSImage>()
    private static let lightCache = NSCache<NSUUID, NSNumber>()

    /// 图片右上角区域是否偏亮(决定叠在上面的按钮用深色还是浅色)。
    /// 缩到 8×8 取右上 3×3 的平均亮度,结果按附件缓存;解码失败按「偏亮」处理(主题底色多为浅色)。
    /// - Parameter attachment: 图片附件
    static func isLightAtTopRight(_ attachment: ImageAttachment) -> Bool {
        let key = attachment.id as NSUUID
        if let hit = lightCache.object(forKey: key) { return hit.boolValue }
        let value = topRightLuminance(of: attachment).map { $0 > 0.55 } ?? true
        lightCache.setObject(NSNumber(value: value), forKey: key)
        return value
    }

    /// 右上角平均亮度(0 深 … 1 亮);透明像素按浅色底合成。
    private static func topRightLuminance(of attachment: ImageAttachment) -> Double? {
        guard let image = image(for: attachment),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let side = 8
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            // 先铺浅色底,再画图,透明区域不会被当成黑色
            context.setFillColor(gray: 0.96, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
            context.interpolationQuality = .medium
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }
        var total = 0.0
        var count = 0.0
        // 位图内存首行即画面顶部:右上角 = 前 3 行的右侧 3 列
        for row in 0..<3 {
            for column in (side - 3)..<side {
                let offset = (row * side + column) * 4
                total += 0.2126 * Double(pixels[offset]) + 0.7152 * Double(pixels[offset + 1]) + 0.0722 * Double(pixels[offset + 2])
                count += 1
            }
        }
        return count > 0 ? total / count / 255 : nil
    }

    static func image(for attachment: ImageAttachment) -> NSImage? {
        let key = attachment.id as NSUUID
        if let hit = cache.object(forKey: key) { return hit }
        guard let image = NSImage(data: attachment.data) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}

/// 助手消息:Markdown 渲染。
struct AssistantMessageView: View {
    let entry: TimelineEntry

    var body: some View {
        MarkdownView(text: entry.text)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 2)
    }
}

/// 思维面板:默认始终折叠(流式中也不自动展开),仅显示计时;是否展开完全由用户决定。
struct ThoughtView: View {
    let entry: TimelineEntry
    @Environment(\.stickyUser) private var scrollState
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                scrollState?.followSuspended = true
                expanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image.om("chevron.right", size: 9, weight: .bold)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    if entry.isStreaming {
                        ActiveTimeline(interval: 1) { _ in
                            Text("思考中… \(Int(entry.elapsedSeconds)) 秒")
                        }
                    } else {
                        Text("已思考 \(max(1, Int(entry.elapsedSeconds.rounded()))) 秒")
                    }
                }
                .font(OMFonts.small)
                .foregroundStyle(OMColors.secondaryText)
            }
            .buttonStyle(.plain)
            if expanded {
                Text(entry.text)
                    .font(OMFonts.small)
                    .foregroundStyle(OMColors.secondaryText)
                    .textSelection(.enabled)
                    .padding(.leading, 15)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// 计划视图。
struct PlanView: View {
    let entry: TimelineEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("计划", om: "list.bullet.clipboard")
                .font(OMFonts.small.weight(.semibold))
                .foregroundStyle(OMColors.secondaryText)
            ForEach(Array(entry.plan.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image.om(icon(item.status))
                        .foregroundStyle(item.status == "completed" ? OMColors.success : OMColors.secondaryText)
                        .frame(width: 14)
                    Text(item.content)
                        .font(OMFonts.reading)
                        .strikethrough(item.status == "completed")
                        .foregroundStyle(item.status == "completed" ? OMColors.secondaryText : OMColors.primaryText)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .omSolidCard()
    }

    private func icon(_ status: String) -> String {
        switch status {
        case "completed": return "checkmark.circle.fill"
        case "in_progress": return "circle.dotted"
        default: return "circle"
        }
    }
}

/// 提示 / 错误(可带 Markdown 详情,如压缩提示、`/help`、`/status`)。
struct NoticeView: View {
    let entry: TimelineEntry

    private var tint: Color {
        switch entry.severity {
        case "error": return OMColors.danger
        case "warning": return OMColors.warning
        default: return OMColors.secondaryText
        }
    }

    private var icon: String {
        switch entry.severity {
        case "error": return "exclamationmark.circle.fill"
        case "warning": return "exclamationmark.triangle.fill"
        default: return entry.isError ? "exclamationmark.circle.fill" : "info.circle"
        }
    }

    var body: some View {
        if entry.isMuted {
            // 第三方 Agent 的指标类通知(如 TPS):淡色等宽小字,无图标
            Text(entry.text)
                .font(OMFonts.monoSmall)
                .foregroundStyle(OMColors.tertiaryText)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            standard
        }
    }

    private var standard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(entry.text, om: icon)
                .font(OMFonts.small)
                .foregroundStyle(tint)
                .textSelection(.enabled)
            if let detail = entry.detail {
                MarkdownView(text: detail)
                    .padding(.leading, 20)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 计划模式批准后的计划文档(Markdown 卡片)。
struct PlanDocView: View {
    let entry: TimelineEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("计划", om: "list.bullet.clipboard")
                .font(OMFonts.small.weight(.semibold))
                .foregroundStyle(OMColors.secondaryText)
            MarkdownView(text: entry.text)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .omSolidCard()
    }
}

/// 输入区上方的待办折叠卡:默认收起为一行「已完成 x / n」,点击展开完整计划。
struct PlanDock: View {
    let model: SessionModel
    @State private var expanded = false

    var body: some View {
        if let entry = model.timeline.entries.last(where: { $0.kind == .plan }), !entry.plan.isEmpty {
            let done = entry.plan.filter { $0.status == "completed" }.count
            VStack(spacing: 0) {
                Button {
                    omWithAnimation { expanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image.om(expanded ? "chevron.down" : "chevron.right", size: 10)
                        Image.om("list-checks", size: 12)
                        Text("待办 \(done)/\(entry.plan.count)").font(OMFonts.small.weight(.medium))
                        Spacer()
                    }
                    .foregroundStyle(OMColors.secondaryText)
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(expanded ? String(localized: "收起待办") : String(localized: "展开待办"))
                if expanded {
                    PlanView(entry: entry).padding([.horizontal, .bottom], 4)
                }
            }
            .omGlassCard(cornerRadius: OMRadius.floating)
        }
    }
}
