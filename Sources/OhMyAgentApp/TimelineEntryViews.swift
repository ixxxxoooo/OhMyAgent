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
        }
    }
}

/// 用户消息:纯色卡片(可带图片缩略图;运行中引导的消息带「引导」标记)。
struct UserMessageView: View {
    let entry: TimelineEntry

    var body: some View {
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
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .omSolidCard()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("你:\(entry.text)")
    }
}

/// 图片附件缩略图(解码结果缓存,避免滚动时重复解码)。
struct AttachmentThumbnail: View {
    let attachment: ImageAttachment
    var size: CGFloat = 56
    /// 非 nil 时在右上角显示移除按钮
    var onRemove: (() -> Void)?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let image = AttachmentImageCache.image(for: attachment) {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Image.om("image", size: 18).foregroundStyle(OMColors.secondaryText)
                }
            }
            .frame(width: size, height: size)
            .background(OMColors.card)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(OMColors.hairline))
            .accessibilityLabel("图片 \(attachment.name)")
            if let onRemove {
                Button(action: onRemove) {
                    Image.om("circle-x", size: 14)
                        .foregroundStyle(.white, Color.black.opacity(0.6))
                }
                .buttonStyle(.plain)
                .padding(2)
                .accessibilityLabel("移除图片")
            }
        }
    }
}

/// 缩略图解码缓存。
@MainActor
enum AttachmentImageCache {
    private static let cache = NSCache<NSUUID, NSImage>()

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
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                omWithAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image.om("chevron.right", size: 9, weight: .bold)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    if entry.isStreaming {
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
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
                        .foregroundStyle(item.status == "completed" ? Color.green : OMColors.secondaryText)
                        .frame(width: 14)
                    Text(item.content)
                        .font(OMFonts.reading)
                        .strikethrough(item.status == "completed")
                        .foregroundStyle(item.status == "completed" ? OMColors.secondaryText : Color.primary)
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
        case "error": return .red
        case "warning": return .orange
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
            .omGlassCard(cornerRadius: 16)
        }
    }
}
