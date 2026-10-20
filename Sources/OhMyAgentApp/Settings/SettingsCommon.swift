// @author ixxxxoooo
// 设置页公共组件:settings.json 绑定、作用域选择器、说明文字。

import IconKit
import ClaudeConfigKit
import DesignSystem
import SwiftUI

extension ClaudeSettingsModel {
    /// 字符串绑定;空串写入时删除该键。
    func stringBinding(_ path: [String]) -> Binding<String> {
        Binding(get: { self.string(path) ?? "" }, set: { self.set(path, $0.isEmpty ? nil : $0) })
    }

    /// 布尔绑定;`defaultValue` 与默认相同时删除该键,保持文件干净。
    func boolBinding(_ path: [String], defaultValue: Bool = false) -> Binding<Bool> {
        Binding(get: { self.bool(path) ?? defaultValue }, set: { self.set(path, $0 == defaultValue ? nil : $0) })
    }

    /// `env` 字典中的单个变量。
    func envBinding(_ name: String) -> Binding<String> {
        Binding(get: { self.dictionary(["env"])[name] ?? "" }, set: { value in
            var env = self.dictionary(["env"])
            if value.isEmpty { env.removeValue(forKey: name) } else { env[name] = value }
            self.set(["env"], env.isEmpty ? nil : env)
        })
    }
}

/// 设置层选择器 + 说明。
struct ScopeHeader: View {
    @Bindable var model: ClaudeSettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 10) {
                Text("写入位置").font(OMFonts.small).foregroundStyle(OMColors.secondaryText)
                Picker("", selection: $model.scope) {
                    ForEach(ConfigScope.allCases) { scope in
                        Text(scope.displayName).tag(scope)
                    }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Spacer()
            }
            Text(verbatim: omLocalized(hint)).font(OMFonts.caption).foregroundStyle(OMColors.tertiaryText)
            if !model.canWriteCurrentScope {
                Label("当前没有工作区,无法写入此层;请先打开一个工作区。", om: "exclamationmark.triangle").font(OMFonts.caption).foregroundStyle(OMColors.warning)
            }
        }
    }

    private var hint: String {
        switch model.scope {
        case .user: return String(localized: "~/.claude/settings.json,对所有项目生效")
        case .project: return String(localized: "<工作区>/.claude/settings.json,可提交到版本库与团队共享")
        case .local: return String(localized: "<工作区>/.claude/settings.local.json,仅本机,不入版本库")
        }
    }
}

/// 卡片内的标签行样式:标签在左、内容靠右(系统样式只在 `Form` 里才右对齐)。
struct SettingsLabeledContentStyle: LabeledContentStyle {
    /// - Parameter configuration: 标签与内容
    /// - Returns: 左右分布的行
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .center, spacing: OMSpacing.md) {
            configuration.label
            Spacer(minLength: OMSpacing.md)
            configuration.content
        }
    }
}

/// 卡片行里的开关样式:标题在左、小号开关靠右(与卡片页 `SettingsToggleRow` 一致)。
struct SettingsSwitchToggleStyle: ToggleStyle {
    /// - Parameter configuration: 标题与开关状态
    /// - Returns: 左右分布的开关行
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .center, spacing: OMSpacing.md) {
            configuration.label
            Spacer(minLength: OMSpacing.md)
            Toggle("", isOn: configuration.$isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }
}

/// 页面骨架:把 `Section` 渲染成与卡片页(`SettingsScroll`/`SettingsCard`)一致的分组卡片,
/// 这样所有设置页的内容区宽度都由「外观 → 设置页宽度」统一控制(系统分组表单自身有宽度上限,不随档位变化)。
struct SettingsForm<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: OMSpacing.xl) {
                Group(sections: content) { sections in
                    ForEach(sections) { section in
                        VStack(alignment: .leading, spacing: OMSpacing.sm) {
                            section.header
                                .font(OMFonts.small)
                                .foregroundStyle(OMColors.secondaryText)
                                .padding(.horizontal, OMSpacing.xs)
                            VStack(alignment: .leading, spacing: 0) {
                                Group(subviews: section.content) { rows in
                                    ForEach(rows.indices, id: \.self) { index in
                                        if index > 0 {
                                            Rectangle().fill(OMColors.hairline).frame(height: 0.5).padding(.horizontal, OMSpacing.md)
                                        }
                                        rows[index]
                                            .labeledContentStyle(SettingsLabeledContentStyle())
                                            .toggleStyle(SettingsSwitchToggleStyle())
                                            .padding(.horizontal, OMSpacing.md)
                                            .padding(.vertical, OMSpacing.sm + 2)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                            }
                            .background(OMColors.card, in: RoundedRectangle(cornerRadius: OMRadius.card, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: OMRadius.card, style: .continuous).strokeBorder(OMColors.hairline, lineWidth: 0.5))
                            section.footer
                                .font(OMFonts.caption)
                                .foregroundStyle(OMColors.secondaryText)
                                .padding(.horizontal, OMSpacing.xs)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, OMSpacing.lg)
            .padding(.vertical, OMSpacing.lg)
        }
        .settingsSurface()
    }
}

extension View {
    /// 设置页内多行文本编辑器(TextEditor)的统一外观:透明底 + 内边距 + 浅底色 + 细描边,
    /// 记忆、提示词、环境变量、MCP/Hook/子 Agent 编辑表单共用,避免各处一套样式。
    func settingsEditorStyle() -> some View {
        scrollContentBackground(.hidden)
            .padding(8)
            .background(OMColors.surface, in: RoundedRectangle(cornerRadius: OMMetrics.controlRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: OMMetrics.controlRadius, style: .continuous).strokeBorder(OMColors.hairline, lineWidth: 0.5))
    }

    /// 设置页右侧内容区统一背景:隐藏系统分组表单/列表自带的底色,铺 `OMColors.surface`,避免上下色差。
    func settingsSurface() -> some View {
        scrollContentBackground(.hidden)
            .background(OMColors.surface)
    }
}

/// 设置页统一的「标签 + 右对齐数字输入 + 可选单位」行,所有数字输入行(超时、预算、行数、缓冲上限)共用,
/// 输入框固定宽度、右对齐,单位占位固定,避免各页错位。
struct SettingsNumericField<Value: Equatable, Format: ParseableFormatStyle>: View where Format.FormatInput == Value, Format.FormatOutput == String {
    let title: LocalizedStringKey
    @Binding var value: Value
    var format: Format
    var unit: String?
    var prompt: String?
    var fieldWidth: CGFloat = 90

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                TextField("", value: $value, format: format, prompt: prompt.map { Text(verbatim: omLocalized($0)) })
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: fieldWidth)
                    .accessibilityLabel(title)
                if let unit {
                    Text(verbatim: omLocalized(unit)).font(OMFonts.small).foregroundStyle(OMColors.secondaryText)
                }
            }
        }
    }
}

/// 设置页「标题 + 当前值 + 档位滑块」行:标题与当前值在上,滑块占满整行宽度(宽度、字号等档位调节统一用它)。
struct SettingsSliderRow: View {
    let title: String
    let valueText: String
    let stops: [String]
    @Binding var index: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(verbatim: title).font(OMFonts.body)
                Spacer(minLength: 8)
                Text(verbatim: valueText).font(OMFonts.small).foregroundStyle(OMColors.secondaryText).monospacedDigit()
            }
            OMStepSlider(stops: stops, index: $index, accessibilityName: title)
        }
        .padding(.vertical, 2)
    }
}

/// 灰色说明文字。
struct Note: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(verbatim: omLocalized(text)).font(OMFonts.caption).foregroundStyle(OMColors.secondaryText).fixedSize(horizontal: false, vertical: true)
    }
}

/// 把以 `String` 传入的中文文案按当前语言取译文(未收录则原样返回)。
/// 返回纯文本:不经过 Markdown 解析,避免 `~`、`*`、`_` 等字符被吞掉。
/// - Parameter key: 中文原文(即 `Localizable.strings` 的键)。
/// - Returns: 当前语言下的译文。
func omLocalized(_ key: String) -> String {
    Bundle.main.localizedString(forKey: key, value: nil, table: nil)
}
