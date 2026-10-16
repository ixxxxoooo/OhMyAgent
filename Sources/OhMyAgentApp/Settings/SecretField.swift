// @author ixxxxoooo
// 密钥输入框:默认以圆点遮挡,右侧眼睛图标切换明文,另有复制按钮。所有保存密钥的地方统一使用它。

import AppKit
import DesignSystem
import IconKit
import SwiftUI

/// 带「显示/隐藏」眼睛图标与复制按钮的密钥输入框。
struct SecretField: View {
    /// 占位文案
    let placeholder: String
    /// 密钥文本
    @Binding var text: String
    @State private var revealed = false
    @State private var copied = false

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if revealed {
                    TextField("", text: $text, prompt: Text(placeholder))
                } else {
                    SecureField("", text: $text, prompt: Text(placeholder))
                }
            }
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .font(OMFonts.monoSmall)
            .autocorrectionDisabled()
            iconButton(revealed ? "eye-off" : "eye", label: revealed ? String(localized: "隐藏密钥") : String(localized: "显示密钥")) { revealed.toggle() }
            iconButton(copied ? "check" : "copy", label: String(localized: "复制密钥")) { copy() }
                .disabled(text.isEmpty)
        }
    }

    private func iconButton(_ name: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image.om(name, size: 14)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(OMColors.secondaryText)
        .help(label)
        .accessibilityLabel(label)
    }

    /// 复制到剪贴板(1.5 秒后恢复图标)。
    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}
