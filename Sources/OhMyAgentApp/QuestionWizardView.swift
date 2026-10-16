// @author ixxxxoooo
// AskUserQuestion 向导卡片(输入栏上方,布局与交互参考 kuku 的问答面板):
// 可折叠标题 + 逐题步骤 + 字母徽标选项 + 「其他」输入行 + 页码与跳过/下一题/提交。
// 单选点选后自动进入下一题;选项多于 6 个时分两列;键盘:A–Z 选择、⏎ 下一题/提交、Esc 跳过。

import ChatKit
import DesignSystem
import IconKit
import SwiftUI

/// 向导卡片。
struct QuestionWizardCard: View {
    let prompt: ElicitationPrompt
    let questions: [ElicitQuestion]
    /// 排在后面等待的提问数量
    let queued: Int
    let onFinish: () -> Void

    @State private var step = 0
    @State private var collapsed = false
    @FocusState private var focus: Focus?

    fileprivate enum Focus { case card, other }

    /// 当前题(越界时回退到最后一题)。
    private var current: ElicitQuestion { questions[min(step, questions.count - 1)] }
    private var isLast: Bool { step >= questions.count - 1 }
    private var unanswered: Int { questions.filter { !$0.isAnswered }.count }
    /// 当前题是否可以前进:必须已作答;最后一题还要求全部题目作答。
    private var canAdvance: Bool { isLast ? unanswered == 0 : current.isAnswered }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !collapsed {
                Divider().opacity(0.5)
                QuestionBody(question: current, optionsHeight: optionsHeight, focus: $focus, onSubmitOther: advance, onPicked: picked)
                    .id(current.id)
                    .padding(12)
                Divider().opacity(0.5)
                footer
            }
        }
        .omGlassCard()
        .focusable()
        .focused($focus, equals: .card)
        .focusEffectDisabled()
        .onKeyPress(phases: .down) { handleKey($0) }
        .onAppear { focus = .card }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Agent 提问")
    }

    // MARK: 头部与底部

    private var header: some View {
        Button {
            omWithAnimation(.snappy(duration: 0.18)) { collapsed.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image.om("chevron-down", size: 11, weight: .bold)
                    .rotationEffect(.degrees(collapsed ? -90 : 0))
                Image.om("message-circle-question-mark", size: 12)
                Text("提问").font(OMFonts.small.weight(.semibold))
                if questions.count > 1 {
                    Text("\(questions.count) 题").font(OMFonts.caption).foregroundStyle(OMColors.tertiaryText)
                }
                Spacer()
                if queued > 0 {
                    OMTag(String(localized: "还有 \(queued) 个待回答"), tint: OMColors.accent)
                }
            }
            .foregroundStyle(OMColors.secondaryText)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(collapsed ? String(localized: "展开提问") : String(localized: "收起提问"))
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if questions.count > 1 {
                pager
            }
            Spacer()
            if isLast, unanswered > 0 {
                Text("还有 \(unanswered) 题未回答")
                    .font(OMFonts.caption)
                    .foregroundStyle(OMColors.tertiaryText)
            }
            Button {
                skip()
            } label: {
                HStack(spacing: 4) {
                    Text("跳过")
                    Text("⎋").foregroundStyle(OMColors.tertiaryText)
                }
            }
            .buttonStyle(.omSecondary)
            .controlSize(.small)
            Button {
                advance()
            } label: {
                HStack(spacing: 4) {
                    Text(isLast ? String(localized: "提交") : String(localized: "下一题"))
                    Text("⏎").opacity(0.7)
                }
            }
            .buttonStyle(.omPrimary)
            .controlSize(.small)
            .disabled(!canAdvance)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// 页码:‹ 1/3 ›
    private var pager: some View {
        HStack(spacing: 2) {
            Button { go(step - 1) } label: { Image.om("chevron-left", size: 11, weight: .bold) }
                .disabled(step == 0)
                .accessibilityLabel("上一题")
            Text("\(step + 1)/\(questions.count)")
                .font(OMFonts.small)
                .monospacedDigit()
                .foregroundStyle(OMColors.secondaryText)
                .frame(minWidth: 30)
            Button { go(step + 1) } label: { Image.om("chevron-right", size: 11, weight: .bold) }
                .disabled(isLast)
                .accessibilityLabel("下一题")
        }
        .buttonStyle(.plain)
        .foregroundStyle(OMColors.secondaryText)
    }

    // MARK: 行为

    /// 选项区预留高度:取各题所需高度的最大值,切换题目时卡片高度保持不变(避免整页抖动);
    /// 超过 260 时选项区内部滚动。
    private var optionsHeight: CGFloat {
        min(questions.map { QuestionBody.estimatedGridHeight(for: $0) }.max() ?? 0, 260)
    }

    private func go(_ target: Int) {
        let clamped = max(0, min(target, questions.count - 1))
        guard clamped != step else { return }
        omWithAnimation(.snappy(duration: 0.15)) { step = clamped }
        focus = .card
    }

    /// 前进:非最后一题进入下一题,最后一题提交。
    private func advance() {
        guard canAdvance else { return }
        if isLast {
            prompt.accept()
            onFinish()
        } else {
            go(step + 1)
        }
    }

    private func skip() {
        prompt.decline()
        onFinish()
    }

    /// 单选点选后自动进入下一题(最后一题不自动提交)。
    private func picked(_ question: ElicitQuestion) {
        guard !question.isMulti, !isLast else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            if current.id == question.id { go(step + 1) }
        }
    }

    /// 键盘:字母选择、回车前进、Esc 跳过、左右翻页。输入「其他」时交给输入框。
    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        guard focus != .other else {
            if press.key == .escape { focus = .card; return .handled }
            return .ignored
        }
        switch press.key {
        case .return:
            advance()
            return .handled
        case .escape:
            skip()
            return .handled
        case .leftArrow:
            go(step - 1)
            return .handled
        case .rightArrow:
            go(step + 1)
            return .handled
        default:
            break
        }
        guard press.modifiers.isEmpty || press.modifiers == .shift,
              let scalar = press.characters.lowercased().unicodeScalars.first,
              (97...122).contains(scalar.value) else { return .ignored }
        let index = Int(scalar.value) - 97
        let question = current
        if index < question.options.count {
            question.choose(question.options[index].value)
            picked(question)
            return .handled
        }
        if index == question.options.count, question.custom != nil {
            focus = .other
            return .handled
        }
        return .ignored
    }
}

// MARK: - 单题内容

/// 单题:徽标 + 题干 + 选项网格 + 「其他」行。
private struct QuestionBody: View {
    let question: ElicitQuestion
    /// 选项区固定高度(由外层按全部题目算出)
    let optionsHeight: CGFloat
    var focus: FocusState<QuestionWizardCard.Focus?>.Binding
    let onSubmitOther: () -> Void
    let onPicked: (ElicitQuestion) -> Void

    /// 选项(含「其他」行)多于 6 个时分两列。
    private var columns: Int { question.options.count + (question.custom == nil ? 0 : 1) > 6 ? 2 : 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                if let header = question.header { OMTag(header, tint: OMColors.accent) }
                if question.isMulti { OMTag(String(localized: "可多选")) }
            }
            .opacity(question.header == nil && !question.isMulti ? 0 : 1)
            .frame(height: question.header == nil && !question.isMulti ? 0 : nil)
            Text(question.prompt)
                .font(OMFonts.body.weight(.medium))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6, alignment: .top), count: columns), spacing: 6) {
                    ForEach(Array(question.options.enumerated()), id: \.element.id) { index, option in
                        optionRow(index: index, option: option)
                    }
                    if question.custom != nil { otherRow }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: optionsHeight)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 估算选项网格高度,用于跨题预留。
    static func estimatedGridHeight(for question: ElicitQuestion) -> CGFloat {
        let count = question.options.count + (question.custom == nil ? 0 : 1)
        let cols = count > 6 ? 2 : 1
        let rowHeights = question.options.map { $0.description == nil ? CGFloat(34) : CGFloat(50) } + (question.custom == nil ? [] : [34])
        let total = rowHeights.reduce(0, +) + CGFloat(max(0, rowHeights.count - 1)) * 6
        return cols == 1 ? total : (total / 2).rounded(.up) + 17
    }

    private func letter(_ index: Int) -> String {
        guard let scalar = UnicodeScalar(65 + index), index < 26 else { return "·" }
        return String(Character(scalar))
    }

    private func badge(_ index: Int, selected: Bool) -> some View {
        Text(letter(index))
            .font(OMFonts.custom(10.5, weight: .semibold, design: .rounded))
            .foregroundStyle(selected ? OMColors.onAccent : OMColors.secondaryText)
            .frame(width: 18, height: 18)
            .background(selected ? OMColors.accent : Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    private func optionRow(index: Int, option: ElicitOption) -> some View {
        let selected = question.field.selection.contains(option.value)
        return Button {
            question.choose(option.value)
            onPicked(question)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                badge(index, selected: selected)
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.title).font(OMFonts.body)
                    if let description = option.description, !description.isEmpty {
                        Text(description)
                            .font(OMFonts.caption)
                            .foregroundStyle(OMColors.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                if selected { Image.om("check", size: 12, weight: .bold).foregroundStyle(OMColors.accent) }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowBackground(selected: selected))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var otherRow: some View {
        let index = question.options.count
        let active = !question.customText.isEmpty
        return HStack(spacing: 8) {
            badge(index, selected: active)
            TextField("其他…", text: Binding(get: { question.custom?.text ?? "" }, set: { question.setCustomText($0) }))
                .textFieldStyle(.plain)
                .font(OMFonts.body)
                .focused(focus, equals: .other)
                .onSubmit(onSubmitOther)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(rowBackground(selected: active))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("其他")
    }

    private func rowBackground(selected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(selected ? OMColors.accent.opacity(0.12) : Color.primary.opacity(0.03))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(selected ? OMColors.accent.opacity(0.5) : OMColors.hairline, lineWidth: 0.5))
    }
}
