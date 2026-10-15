// @author ygw
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
            HStack {
                Text("写入位置").font(OMFonts.small).foregroundStyle(OMColors.secondaryText)
                Picker("", selection: $model.scope) {
                    ForEach(ConfigScope.allCases) { scope in
                        Text(scope.displayName).tag(scope)
                    }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 220)
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

/// 页面骨架:分组表单 + 可选的顶部内容。
struct SettingsForm<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        Form { content }
            .formStyle(.grouped)
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
