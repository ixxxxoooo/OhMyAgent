// @author ixxxxoooo
// 折叠分组的「最新一步」行(对齐 Cursor):分组运行中且折叠时,标题行下方固定一行当前正在执行的步骤,
// 新步骤从下方滚入、旧步骤向上挤出,最新一行带流光;分组结束后收起。

import ACPKit
import ChatKit
import DesignSystem
import IconKit
import SwiftUI

/// 分组运行中的最新一步(单行,只显示最后一个工具)。
struct GroupLatestStepView: View {
    let group: ExploreGroup
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 最后一个工具条目。
    /// - Returns: 工具条目;分组内没有工具时为 nil
    private var latest: TimelineEntry? {
        group.entries.last { $0.kind == .tool && $0.tool != nil }
    }

    var body: some View {
        // 固定一行高度并裁切:新旧两行在容器内滚动交替,不改变外部布局高度
        ZStack(alignment: .leading) {
            if let entry = latest, let tool = entry.tool {
                row(for: tool)
                    .id(entry.id)
                    .transition(reduceMotion ? .opacity : .asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .move(edge: .top).combined(with: .opacity)))
            }
        }
        .frame(height: 22, alignment: .leading)
        .clipped()
        .padding(.leading, 28)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: latest?.id)
    }

    /// 一行步骤:图标 + 动词 + 对象(命令取首行),运行中带流光。
    /// - Parameter tool: 工具调用
    /// - Returns: 行视图
    private func row(for tool: ToolCall) -> some View {
        let presentation = ToolPresentation(tool: tool)
        let subject = presentation.subject.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return HStack(spacing: 6) {
            Image.om(ToolIcons.symbol(for: presentation.category), size: 11)
                .foregroundStyle(OMColors.tertiaryText)
            Text(subject.isEmpty ? presentation.verb : "\(presentation.verb) \(subject)")
                .font(OMFonts.small)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(OMColors.secondaryText)
                .flowingText(!tool.status.isTerminal)
        }
    }
}
