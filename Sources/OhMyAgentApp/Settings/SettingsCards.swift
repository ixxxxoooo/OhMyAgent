// @author ixxxxoooo
// 设置页「卡片行」骨架(Cursor 风格):分组标题在卡片外,卡片内每行「标题+说明在左、控件在右」,发丝线分隔。
// 与 `SettingsForm`(系统分组表单)并存:新页面与已迁移页面用这套,其余页面后续再迁。

import DesignSystem
import SwiftUI

/// 标记「脚注」子视图的容器值:卡片里脚注不画上方分隔线,并使用更紧的内边距。
extension ContainerValues {
    @Entry var settingsIsFootnote: Bool = false
}

/// 设置页骨架:纵向滚动的卡片列表,背景取内容区色。
struct SettingsScroll<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: OMSpacing.xl) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, OMSpacing.lg)
            .padding(.vertical, OMSpacing.lg)
        }
        .background(OMColors.surface)
    }
}

/// 设置分组卡片:标题在外,圆角容器内按行排布,行间发丝线。
struct SettingsCard<Content: View>: View {
    let title: LocalizedStringKey?
    @ViewBuilder var content: Content

    /// - Parameters:
    ///   - title: 分组标题(可省略)
    ///   - content: 行内容(`SettingsRow` / `SettingsToggleRow` / `Note` 或任意视图)
    init(_ title: LocalizedStringKey? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: OMSpacing.sm) {
            if let title {
                Text(title)
                    .font(OMFonts.small)
                    .foregroundStyle(OMColors.secondaryText)
                    .padding(.horizontal, OMSpacing.xs)
            }
            VStack(spacing: 0) {
                Group(subviews: content) { subviews in
                    ForEach(subviews.indices, id: \.self) { index in
                        let foot = subviews[index].containerValues.settingsIsFootnote
                        if index > 0 && !foot { Rectangle().fill(OMColors.hairline).frame(height: 0.5).padding(.horizontal, OMSpacing.md) }
                        subviews[index]
                            .padding(.horizontal, OMSpacing.md)
                            .padding(.top, foot ? 0 : OMSpacing.sm + 2)
                            .padding(.bottom, OMSpacing.sm + 2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .background(OMColors.card, in: RoundedRectangle(cornerRadius: OMRadius.card, style: .continuous))
        }
    }
}

/// 设置行:左侧标题(+说明),右侧控件。
struct SettingsRow<Control: View>: View {
    let title: String
    let detail: String?
    @ViewBuilder var control: Control

    /// - Parameters:
    ///   - title: 行标题(中文原文,按当前语言取译文)
    ///   - detail: 说明文字(可选)
    ///   - control: 右侧控件
    init(_ title: String, detail: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.detail = detail
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .center, spacing: OMSpacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: omLocalized(title)).font(OMFonts.body).foregroundStyle(OMColors.primaryText)
                if let detail {
                    Text(verbatim: omLocalized(detail))
                        .font(OMFonts.small)
                        .foregroundStyle(OMColors.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: OMSpacing.md)
            control
        }
    }
}

/// 带开关的设置行。
struct SettingsToggleRow: View {
    let title: String
    let detail: String?
    @Binding var isOn: Bool

    /// - Parameters:
    ///   - title: 行标题
    ///   - detail: 说明文字(可选)
    ///   - isOn: 开关绑定
    init(_ title: String, detail: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.detail = detail
        _isOn = isOn
    }

    var body: some View {
        SettingsRow(title, detail: detail) {
            Toggle(omLocalized(title), isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }
}

extension Note {
    /// 在卡片内作为脚注显示(无上方分隔线)。
    func footnote() -> some View { containerValue(\.settingsIsFootnote, true) }
}
