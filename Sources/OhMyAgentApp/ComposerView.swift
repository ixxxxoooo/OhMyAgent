// @author ygw
// 输入区:玻璃浮层,包含输入框、模式/模型菜单、发送与停止按钮。

import ACPKit
import ChatKit
import DesignSystem
import SwiftUI

/// 输入区视图。
struct ComposerView: View {
    @Bindable var model: SessionModel
    @State private var textHeight: CGFloat = 34

    var body: some View {
        VStack(spacing: 6) {
            ComposerTextView(
                text: $model.draft,
                height: $textHeight,
                placeholder: placeholder,
                onSubmit: { model.sendDraft() },
                onEscape: { if model.isRunning { model.cancel() } }
            )
            .frame(height: textHeight)
            HStack(spacing: 6) {
                OptionMenu(model: model, category: "mode", icon: "slider.horizontal.3")
                OptionMenu(model: model, category: "model", icon: "cpu")
                OptionMenu(model: model, category: "thought_level", icon: "brain")
                Spacer(minLength: 8)
                if let queued = model.queuedPrompt {
                    Text("连接后发送:\(queued)")
                        .font(OMFonts.caption)
                        .foregroundStyle(OMColors.secondaryText)
                        .lineLimit(1)
                }
                sendButton
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .omGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var placeholder: String {
        switch model.phase {
        case .connecting: return "正在连接 Agent,可以先输入…"
        case .failed: return "Agent 未连接,发送将尝试重新连接"
        default: return "向 \(model.agentName) 提问,Return 发送,Shift+Return 换行"
        }
    }

    @ViewBuilder
    private var sendButton: some View {
        if model.isRunning {
            Button { model.cancel() } label: {
                Image(systemName: "stop.fill").font(.system(size: 11, weight: .bold)).frame(width: 26, height: 26)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .help("停止 (Esc)")
            .accessibilityLabel("停止生成")
        } else {
            Button { model.sendDraft() } label: {
                Image(systemName: "arrow.up").font(.system(size: 12, weight: .bold)).frame(width: 26, height: 26)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .keyboardShortcut(.return, modifiers: .command)
            .help("发送 (Return)")
            .accessibilityLabel("发送")
        }
    }
}

/// 配置选项菜单(模式 / 模型 / 思考强度),取自会话的 configOptions。
struct OptionMenu: View {
    let model: SessionModel
    let category: String
    let icon: String

    var body: some View {
        if let option = model.option(category: category), !option.options.isEmpty {
            Menu {
                ForEach(option.options, id: \.value) { item in
                    Button {
                        model.setConfigOption(option.id, value: item.value)
                    } label: {
                        if option.currentValue.stringValue == item.value {
                            Label(item.name, systemImage: "checkmark")
                        } else {
                            Text(item.name)
                        }
                    }
                }
            } label: {
                Label(option.currentDisplayName, systemImage: icon)
                    .font(OMFonts.small)
                    .lineLimit(1)
            }
            .fixedSize()
            .menuStyle(.button)
            .buttonStyle(.plain)
            .foregroundStyle(OMColors.secondaryText)
            .help(option.name)
        }
    }
}
