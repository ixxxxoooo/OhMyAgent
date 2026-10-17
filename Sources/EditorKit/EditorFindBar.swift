// @author ixxxxoooo
// 编辑器内查找/替换条:悬浮在编辑区右上角,配色、圆角、字号全部取自主题令牌。

import DesignSystem
import IconKit
import Observation
import SwiftUI

/// 查找条的状态与回调(由 `CodeEditorView` 持有并驱动)。
@MainActor
@Observable
public final class EditorFindModel {
    /// 查询词
    var query = "" { didSet { if query != oldValue { onSearchChange?() } } }
    /// 替换内容
    var replacement = ""
    /// 查找选项
    var options = EditorFindOptions() { didSet { if options != oldValue { onSearchChange?() } } }
    /// 是否展开替换行
    var showsReplace = false
    /// 文档是否可编辑(只读时隐藏替换)
    var isEditable = true
    /// 匹配总数
    var matchCount = 0
    /// 当前匹配下标(0 起)
    var currentIndex: Int?
    /// 正则是否非法
    var isInvalidPattern = false
    /// 递增即请求把键盘焦点放进查询框
    var focusToken = 0

    var onSearchChange: (() -> Void)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onReplace: (() -> Void)?
    var onReplaceAll: (() -> Void)?
    var onClose: (() -> Void)?
}

/// 查找条视图。
struct EditorFindBar: View {
    @Bindable var model: EditorFindModel
    @FocusState private var queryFocused: Bool

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                if model.isEditable {
                    Button { model.showsReplace.toggle() } label: {
                        Image.om(model.showsReplace ? "chevron-down" : "chevron-right", size: 12).frame(width: 16, height: 24)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(OMColors.tertiaryText)
                    .omTooltip(model.showsReplace ? String(localized: "收起替换") : String(localized: "展开替换"))
                    .accessibilityLabel(model.showsReplace ? String(localized: "收起替换") : String(localized: "展开替换"))
                }
                field(text: $model.query, placeholder: String(localized: "查找")) {
                    toggle("Aa", help: String(localized: "区分大小写"), isOn: $model.options.caseSensitive)
                    toggle("ab", help: String(localized: "全词匹配"), isOn: $model.options.wholeWord, underlined: true)
                    toggle(".*", help: String(localized: "正则表达式"), isOn: $model.options.regex)
                }
                .focused($queryFocused)
                .onKeyPress(keys: [.return], phases: .down) { press in
                    if press.modifiers.contains(.shift) { model.onPrevious?() } else { model.onNext?() }
                    return .handled
                }
                .onKeyPress(.escape) { model.onClose?(); return .handled }
                Text(verbatim: countText)
                    .font(OMFonts.caption.monospacedDigit())
                    .foregroundStyle(noResult ? OMColors.danger : OMColors.tertiaryText)
                    .frame(minWidth: 44, alignment: .trailing)
                    .lineLimit(1)
                iconButton("chevron-up", help: String(localized: "上一个 (⇧↩)")) { model.onPrevious?() }
                iconButton("chevron-down", help: String(localized: "下一个 (↩)")) { model.onNext?() }
                iconButton("x", help: String(localized: "关闭 (Esc)")) { model.onClose?() }
            }
            if model.showsReplace && model.isEditable {
                HStack(spacing: 4) {
                    Spacer().frame(width: 16)
                    field(text: $model.replacement, placeholder: String(localized: "替换")) { EmptyView() }
                        .onKeyPress(.return) { model.onReplace?(); return .handled }
                        .onKeyPress(.escape) { model.onClose?(); return .handled }
                    Button("替换") { model.onReplace?() }
                        .buttonStyle(.omSecondary)
                        .disabled(model.matchCount == 0)
                    Button("全部替换") { model.onReplaceAll?() }
                        .buttonStyle(.omSecondary)
                        .disabled(model.matchCount == 0)
                }
            }
        }
        .padding(6)
        .frame(width: model.showsReplace && model.isEditable ? 420 : 360)
        .background(OMColors.card, in: RoundedRectangle(cornerRadius: OMRadius.floating, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: OMRadius.floating, style: .continuous).strokeBorder(OMColors.hairline, lineWidth: 0.5))
        .omFloatingShadow()
        .padding(12)
        .onChange(of: model.focusToken, initial: true) { queryFocused = true }
    }

    private var noResult: Bool { model.isInvalidPattern || (!model.query.isEmpty && model.matchCount == 0) }

    private var countText: String {
        if model.query.isEmpty { return "" }
        if model.isInvalidPattern { return String(localized: "正则无效") }
        if model.matchCount == 0 { return String(localized: "无结果") }
        return "\((model.currentIndex ?? 0) + 1)/\(model.matchCount)"
    }

    /// 带底色的输入框,右侧可放选项开关。
    private func field<Trailing: View>(text: Binding<String>, placeholder: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 2) {
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(OMFonts.small)
                .foregroundStyle(OMColors.primaryText)
                .padding(.leading, 6)
            trailing()
        }
        .frame(height: 24)
        .padding(.trailing, 2)
        .background(OMColors.subtleFill, in: RoundedRectangle(cornerRadius: OMRadius.tag, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: OMRadius.tag, style: .continuous).strokeBorder(OMColors.hairline.opacity(0.6), lineWidth: 0.5))
    }

    /// 选项开关(文字徽标)。
    private func toggle(_ title: String, help: String, isOn: Binding<Bool>, underlined: Bool = false) -> some View {
        Button { isOn.wrappedValue.toggle() } label: {
            Text(verbatim: title)
                .font(OMFonts.monoSmall)
                .underline(underlined)
                .foregroundStyle(isOn.wrappedValue ? OMColors.accentText : OMColors.tertiaryText)
                .frame(width: 22, height: 20)
                .background(isOn.wrappedValue ? OMColors.selectedFill : .clear, in: RoundedRectangle(cornerRadius: OMRadius.tag, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .omTooltip(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(isOn.wrappedValue ? .isSelected : [])
    }

    private func iconButton(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image.om(icon, size: 12) }
            .buttonStyle(.omIcon)
            .omTooltip(help)
            .accessibilityLabel(help)
    }
}
