// @author ixxxxoooo
// 表单里的下拉选择框:外观与 `OMFieldStyle` 输入框一致,点击弹出统一的 `OMPickList`(顶部搜索、↑↓、回车、Esc、当前项打勾)。
// 取代系统 `Picker` 的菜单样式(规范禁止用 `.pickerStyle(.menu)` 做选择)。

import DesignSystem
import IconKit
import SwiftUI

/// 表单下拉选择框。
struct OMSelectField<Value: Hashable>: View {
    /// 选项(值与显示标题)
    let options: [(value: Value, title: String)]
    @Binding var selection: Value
    /// 无障碍标签
    let accessibilityName: String
    /// 控件宽度
    var width: CGFloat = 220
    @State private var shown = false
    @Environment(\.isEnabled) private var isEnabled

    /// 当前选中项的显示标题。
    private var currentTitle: String { options.first { $0.value == selection }?.title ?? "" }

    var body: some View {
        Button { shown.toggle() } label: {
            HStack(spacing: OMSpacing.sm) {
                Text(verbatim: currentTitle).font(OMFonts.body).lineLimit(1)
                Spacer(minLength: 0)
                Image.om("chevrons-up-down", size: 12).foregroundStyle(OMColors.tertiaryText)
            }
            .padding(.horizontal, OMSpacing.sm)
            .frame(width: width, height: 28)
            .background(OMColors.card, in: RoundedRectangle(cornerRadius: OMRadius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: OMRadius.control, style: .continuous).strokeBorder(OMColors.hairline, lineWidth: 0.5))
            .contentShape(RoundedRectangle(cornerRadius: OMRadius.control, style: .continuous))
            .opacity(isEnabled ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityName)
        .accessibilityValue(currentTitle)
        .omPicker(isPresented: $shown, entries: options.enumerated().map { PickEntry(id: "\($0.offset)", title: $0.element.title) },
                  selectedID: options.firstIndex { $0.value == selection }.map(String.init), placement: .below, width: width) { entry in
            if let index = Int(entry.id), options.indices.contains(index) { selection = options[index].value }
        }
    }
}
