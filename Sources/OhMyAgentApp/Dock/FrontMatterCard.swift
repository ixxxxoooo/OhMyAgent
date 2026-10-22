// @author ixxxxoooo
// Markdown 阅读页的前置元数据属性卡片:把 `---` 包围的 YAML 键值渲染成「键 | 值」两列,
// 布尔值显示为是/否标签,列表拆成小标签;解析不了的复杂 YAML 由调用方退回源码显示。

import DesignSystem
import EditorKit
import IconKit
import SwiftUI

/// 前置元数据属性卡片。
struct FrontMatterCard: View {
    let fields: [FrontMatterField]

    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: OMSpacing.lg, verticalSpacing: OMSpacing.sm) {
            ForEach(Array(fields.enumerated()), id: \.offset) { _, field in
                GridRow {
                    Text(field.key)
                        .font(OMFonts.small)
                        .foregroundStyle(OMColors.secondaryText)
                        .gridColumnAlignment(.leading)
                        .padding(.top, 1)
                    valueView(field.value)
                }
            }
        }
        .padding(.horizontal, OMSpacing.md).padding(.vertical, OMSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .omSolidCard()
        .accessibilityElement(children: .combine)
    }

    /// 单个值的呈现。
    /// - Parameter value: 字段值
    /// - Returns: 文本、是/否标签或标签流
    @ViewBuilder
    private func valueView(_ value: FrontMatterValue) -> some View {
        switch value {
        case .text(let text):
            Text(text.isEmpty ? "—" : text)
                .font(OMFonts.body)
                .foregroundStyle(text.isEmpty ? OMColors.tertiaryText : OMColors.primaryText)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .bool(let flag):
            tag(flag ? String(localized: "是") : String(localized: "否"), icon: flag ? "check" : "x", tint: flag ? OMColors.success : OMColors.tertiaryText)
        case .list(let items):
            OMFlowLayout(spacing: OMSpacing.xs + 2, lineSpacing: OMSpacing.xs + 2) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    tag(item, icon: nil, tint: OMColors.primaryText, mono: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 小标签。
    private func tag(_ text: String, icon: String?, tint: Color, mono: Bool = false) -> some View {
        HStack(spacing: OMSpacing.xs) {
            if let icon { Image.om(icon, size: 12) }
            Text(text).font(mono ? OMFonts.monoSmall : OMFonts.small)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, OMSpacing.sm).padding(.vertical, 2)
        .background(OMPillShape().fill(OMColors.subtleFill))
        .overlay(OMPillShape().strokeBorder(OMColors.hairline, lineWidth: 0.5))
    }
}
