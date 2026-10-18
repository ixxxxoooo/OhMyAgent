// @author ixxxxoooo
// 折叠分组的「最新一步」行(对齐 Cursor):分组运行中且折叠时,标题行下方固定一行当前正在执行的步骤,
// 新步骤从下方滚入、旧步骤向上挤出,最新一行带流光;分组结束后收起。

import ACPKit
import ChatKit
import DesignSystem
import IconKit
import SwiftUI

/// 分组运行中的最新一步(单行,只显示最后一个工具)。
/// 工具之间的空窗(上一步已结束、下一步未开始)延迟 0.3 秒后显示「规划下一步…」,避免闪烁;
/// 等待期间旧行原地保留(停止流光),画面始终有一行。点击行等同于点击分组标题(展开/收起)。
struct GroupLatestStepView: View {
    let group: ExploreGroup
    /// 点击回调:展开分组
    var onTap: () -> Void = {}
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var gapReady = false

    /// 是否在尾部思考:行里显示「思考中…」(占原位,不另起一行)。
    private var thinking: Bool { group.isThinkingTail }

    /// 单行高度(容器与每一行一致,滚动位移恰为一整行)。
    private static let rowHeight: CGFloat = 22

    /// 要展示的工具条目(并行时取仍在运行的最后一个)。
    private var latest: TimelineEntry? { group.tickerEntry }

    /// 是否处于工具之间的空窗:没有任何运行中的工具。
    private var inGap: Bool { group.isBetweenSteps }

    /// 是否显示「规划下一步」行:处于空窗且延迟已到。
    private var showsPlanning: Bool { inGap && gapReady && !thinking }

    var body: some View {
        // 固定一行高度并裁切:新旧两行在容器内滚动交替,不改变外部布局高度
        ZStack(alignment: .leading) {
            if thinking {
                stateRow(icon: "brain", text: "思考中…").id("thinking")
                    .transition(rowTransition)
            } else if showsPlanning {
                stateRow(icon: "sparkles", text: "规划下一步…").id("planning")
                    .transition(rowTransition)
            } else if let entry = latest, let tool = entry.tool {
                row(for: tool)
                    .id(entry.id)
                    .transition(rowTransition)
            } else {
                stateRow(icon: "sparkles", text: "规划下一步…").id("planning")
                    .transition(rowTransition)
            }
        }
        .frame(height: Self.rowHeight, alignment: .leading)
        .clipped()
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .accessibilityAddTraits(.isButton)
        .padding(.leading, 28)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: latest?.id)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: showsPlanning)
        .task(id: GapKey(toolID: latest?.id, inGap: inGap && !thinking)) {
            // 新工具开始、或最后一个工具刚结束(进入空窗)时重新计时:先收起「规划」行,空窗持续 0.3 秒后才出现
            gapReady = false
            guard inGap else { return }
            try? await Task.sleep(for: .milliseconds(300))
            if !Task.isCancelled { gapReady = true }
        }
    }

    /// 空窗计时任务的标识:工具变化或「是否空窗」变化都要重新计时。
    private struct GapKey: Equatable {
        let toolID: UUID?
        let inGap: Bool
    }

    /// 行的滚入/滚出过渡:纯位移、无淡入淡出(对齐 kuku),新行从底部滑入的同时旧行被整行顶出顶部;
    /// 每行固定为容器高度,位移距离恰为一整行。
    private var rowTransition: AnyTransition {
        reduceMotion ? .opacity : .asymmetric(insertion: .move(edge: .bottom), removal: .move(edge: .top))
    }

    /// 状态行(「规划下一步…」「思考中…」):工具之间的空窗或尾部思考。
    /// - Parameters:
    ///   - icon: 图标名
    ///   - text: 文案
    /// - Returns: 行视图
    private func stateRow(icon: String, text: LocalizedStringKey) -> some View {
        HStack(spacing: 6) {
            Image.om(icon, size: 11)
                .foregroundStyle(OMColors.tertiaryText)
            Text(text)
                .font(OMFonts.small)
                .lineLimit(1)
                .foregroundStyle(OMColors.secondaryText)
                .flowingText(true)
        }
        .frame(height: Self.rowHeight, alignment: .leading)
    }

    /// 一行步骤:图标 + 动词 + 对象(命令取首行),运行中带流光;空窗等待期间保留旧行但停止流光。
    /// - Parameter tool: 工具调用
    /// - Returns: 行视图
    private func row(for tool: ToolCall) -> some View {
        let presentation = ToolPresentation(tool: tool)
        var subject = presentation.subject.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        // 绝对路径只显示文件名(对齐 Cursor),避免一行被长路径占满
        if subject.hasPrefix("/"), !subject.contains(" ") { subject = (subject as NSString).lastPathComponent }
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
        .frame(height: Self.rowHeight, alignment: .leading)
    }
}

extension EnvironmentValues {
    /// 该时间线条目是否是「进行中会话的最后一项」:分组据此决定要不要显示「规划下一步」(后面还会有下一步)。
    @Entry var liveTail: Bool = false
}
