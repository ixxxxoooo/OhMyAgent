// @author ixxxxoooo
// 模型列表的公共视图:厂商图标 + 模型名 + 纯图标复制按钮,以及带搜索的分组选择列表(弹层用)。
// 所有展示模型的列表(设置页、模型映射、输入区)统一使用,保证都带厂商 logo 与复制按钮。

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
        .help(copied ? String(localized: "已复制") : label)
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
struct ModelPickerRow: Identifiable {
    var id: String
    var name: String
    var detail: String?
    /// 厂商图标;nil 表示该行没有图标(如「跟随默认」)
    var brand: BrandIcon?
    /// 复制文本;nil 不显示复制按钮
    var copyText: String?
    var isSelected = false
}

/// 选择列表的一个分组。
struct ModelPickerSection: Identifiable {
    var id: String
    var title: String?
    var rows: [ModelPickerRow]
}

/// 分组选择列表(用于弹层):可选搜索框;每行 = 厂商图标 + 名称 + 复制按钮 + 选中对勾。
struct ModelPickerList: View {
    let sections: [ModelPickerSection]
    var searchable = false
    let onPick: (String) -> Void
    @State private var query = ""
    @State private var hovered: String?

    private var visible: [ModelPickerSection] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return sections }
        return sections.compactMap { section in
            let rows = section.rows.filter {
                $0.name.lowercased().contains(needle) || ($0.copyText ?? "").lowercased().contains(needle) || (section.title ?? "").lowercased().contains(needle)
            }
            return rows.isEmpty ? nil : ModelPickerSection(id: section.id, title: section.title, rows: rows)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if searchable {
                HStack(spacing: 6) {
                    Image.om("search", size: 12).foregroundStyle(OMColors.tertiaryText)
                    TextField("搜索模型", text: $query).textFieldStyle(.plain).font(OMFonts.small)
                }
                .padding(.horizontal, 10).frame(height: 30)
                Divider()
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(visible) { section in
                        if let title = section.title {
                            Text(verbatim: title).font(OMFonts.caption).foregroundStyle(OMColors.tertiaryText)
                                .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 2)
                        }
                        ForEach(section.rows) { row in rowView(row) }
                    }
                    if visible.isEmpty {
                        Text("没有匹配的模型").font(OMFonts.small).foregroundStyle(OMColors.secondaryText).padding(12)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 320)
        }
        .frame(width: 300)
    }

    private func rowView(_ row: ModelPickerRow) -> some View {
        HStack(spacing: 7) {
            if let brand = row.brand { BrandIconView(brand, size: 14) }
            Text(verbatim: row.name).font(OMFonts.small).lineLimit(1)
            if let detail = row.detail { Text(verbatim: detail).font(OMFonts.caption).foregroundStyle(OMColors.tertiaryText).lineLimit(1) }
            if let copy = row.copyText { ModelCopyButton(text: copy) }
            Spacer(minLength: 4)
            if row.isSelected { Image.om("checkmark", size: 11).foregroundStyle(OMColors.accent) }
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(hovered == row.id ? Color.primary.opacity(0.07) : Color.clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onHover { hovered = $0 ? row.id : (hovered == row.id ? nil : hovered) }
        .onTapGesture { onPick(row.id) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(row.name)
        .accessibilityAddTraits(row.isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
