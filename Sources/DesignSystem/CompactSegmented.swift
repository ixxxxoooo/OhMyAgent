// @author ixxxxoooo
// 紧凑分段控件:选中项只有轻量底色(不抢占强调色),替代系统分段控件的厚重外观;
// 「源码 | 预览」「全部 | 已暂存 | 未暂存」「并排 | 统一」等同类控件统一使用它,避免同一行出现多个橙色高亮。

import SwiftUI

/// 紧凑分段控件。
public struct OMCompactSegmented<Value: Hashable>: View {
    private let options: [(value: Value, title: String)]
    private let selection: Value
    private let accessibilityName: String
    private let onSelect: (Value) -> Void

    /// - Parameters:
    ///   - options: 选项(值与标题)
    ///   - selection: 当前选中值
    ///   - accessibilityName: 无障碍标签(整组控件)
    ///   - onSelect: 点选回调
    public init(
        options: [(value: Value, title: String)],
        selection: Value,
        accessibilityName: String,
        onSelect: @escaping (Value) -> Void
    ) {
        self.options = options
        self.selection = selection
        self.accessibilityName = accessibilityName
        self.onSelect = onSelect
    }

    /// 绑定版本。
    public init(
        options: [(value: Value, title: String)],
        selection: Binding<Value>,
        accessibilityName: String
    ) {
        self.init(options: options, selection: selection.wrappedValue, accessibilityName: accessibilityName) { selection.wrappedValue = $0 }
    }

    public var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, item in
                let selected = item.value == selection
                Button { onSelect(item.value) } label: {
                    Text(LocalizedStringKey(item.title))
                        .font(OMFonts.caption)
                        .foregroundStyle(selected ? Color.primary : OMColors.secondaryText)
                        .padding(.horizontal, 9)
                        .frame(height: 20)
                        .background(Capsule().fill(selected ? Color.primary.opacity(0.1) : .clear))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.primary.opacity(0.04)))
        .overlay(Capsule().strokeBorder(OMColors.hairline.opacity(0.6), lineWidth: 0.5))
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityName)
    }
}
