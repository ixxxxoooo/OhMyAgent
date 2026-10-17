// @author ixxxxoooo
// 模型列表的公共视图:厂商图标 + 模型名 + 纯图标复制按钮,以及带搜索的分组选择列表(弹层用)。
// 所有展示模型的列表(设置页、模型映射、输入区)统一使用,保证都带厂商 logo 与复制按钮。

import ChatKit
import DesignSystem
import IconKit
import SwiftUI

/// 纯图标复制按钮:点击复制文本并短暂显示对勾。
struct ModelCopyButton: View {
    let text: String
    /// 无障碍与提示文案(默认「复制模型名」)
    var label = String(localized: "复制模型名")
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        } label: {
            Image.om(copied ? "check" : "copy", size: 11)
                .foregroundStyle(copied ? OMColors.success : OMColors.tertiaryText)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .omTooltip(copied ? String(localized: "已复制") : label)
        .accessibilityLabel(copied ? String(localized: "已复制") : label)
    }
}

/// 模型名一行:厂商图标 + 名称(+ 副标题)+ 复制按钮。
struct ModelNameRow: View {
    let brand: BrandIcon
    let name: String
    var detail: String?
    /// 复制的文本(通常是模型 ID);nil 时不显示复制按钮
    var copyText: String?

    var body: some View {
        HStack(spacing: 7) {
            BrandIconView(brand, size: 14)
            Text(verbatim: name).font(OMFonts.body).lineLimit(1)
            if let detail { Text(verbatim: detail).font(OMFonts.caption).foregroundStyle(OMColors.tertiaryText).lineLimit(1) }
            if let copyText { ModelCopyButton(text: copyText) }
        }
    }
}

/// 选择列表的一行。
struct ModelPickerRow: PickListItem {
    var id: String
    var name: String
    var detail: String?
    /// 厂商图标;nil 表示该行没有图标(如「跟随默认」)
    var brand: BrandIcon?
    /// 复制文本;nil 不显示复制按钮
    var copyText: String?
    var isSelected = false
    /// 分组标题(提供商名);nil 不分组
    var group: String?

    var searchText: String { [name, detail ?? "", copyText ?? "", group ?? ""].joined(separator: " ") }
}

/// 选择列表的一个分组。
struct ModelPickerSection: Identifiable {
    var id: String
    var title: String?
    var rows: [ModelPickerRow]

    /// 把多个分组摊平成带分组标题的行(`PickListContent` 使用)。
    static func flatten(_ sections: [ModelPickerSection]) -> [ModelPickerRow] {
        sections.flatMap { section in section.rows.map { row in var copy = row; copy.group = section.title; return copy } }
    }
}

/// 模型行内容:厂商图标 + 名称 + 副标题 + 复制按钮(选中对勾与高亮由 `PickListContent` 绘制)。
struct ModelPickRowContent: View {
    let row: ModelPickerRow

    var body: some View {
        HStack(spacing: 7) {
            if let brand = row.brand { BrandIconView(brand, size: 14) }
            Text(verbatim: row.name).font(OMFonts.small).lineLimit(1)
            if let detail = row.detail { Text(verbatim: detail).font(OMFonts.caption).foregroundStyle(OMColors.tertiaryText).lineLimit(1) }
            if let copy = row.copyText { ModelCopyButton(text: copy) }
        }
    }
}

/// 分组选择列表(内嵌在已有弹层/卡片里使用,如设置页的模型映射):搜索 + ↑↓ + 回车 + 打勾,
/// 内核与浮层选择器共用 `PickListContent`。
struct ModelPickerList: View {
    let sections: [ModelPickerSection]
    var searchable = false
    var onDismiss: () -> Void = {}
    let onPick: (String) -> Void

    var body: some View {
        let rows = ModelPickerSection.flatten(sections)
        PickListContent(items: rows, selectedID: rows.first(where: \.isSelected)?.id, placeholder: String(localized: "搜索模型"), showsSearch: searchable,
                        emptyText: String(localized: "没有匹配的模型"), row: { ModelPickRowContent(row: $0) },
                        onSelect: { onPick($0.id) }, onDismiss: onDismiss)
            .frame(width: 300)
    }
}
