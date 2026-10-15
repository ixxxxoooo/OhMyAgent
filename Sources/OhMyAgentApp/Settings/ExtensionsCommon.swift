// @author ygw
// 管理页公共组件:状态条、徽标、空状态、分栏容器。

import IconKit
import ClaudeConfigKit
import DesignSystem
import SwiftUI

/// 顶部状态条:忙碌提示、错误与成功提示(成功提示 3 秒后自动消失)。
struct StatusBanner: View {
    let center: ConfigCenter

    var body: some View {
        VStack(spacing: 0) {
            if let message = center.busyMessage {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(message).font(OMFonts.small)
                    Spacer()
                }
                .padding(.horizontal, 16).padding(.vertical, 6)
                .background(OMColors.card)
            }
            if let error = center.lastError {
                HStack(alignment: .top, spacing: 8) {
                    Image.om("xmark.octagon.fill").foregroundStyle(.red)
                    Text(error).font(OMFonts.small).textSelection(.enabled).lineLimit(4)
                    Spacer()
                    Button { center.lastError = nil } label: { Image.om("xmark") }.buttonStyle(.plain)
                        .accessibilityLabel("关闭错误提示")
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(Color.red.opacity(0.1))
            } else if let notice = center.lastNotice {
                HStack(spacing: 8) {
                    Image.om("checkmark.circle.fill").foregroundStyle(.green)
                    Text(notice).font(OMFonts.small)
                    Spacer()
                }
                .padding(.horizontal, 16).padding(.vertical, 6)
                .background(Color.green.opacity(0.08))
                .task(id: notice) {
                    try? await Task.sleep(for: .seconds(3))
                    if center.lastNotice == notice { center.lastNotice = nil }
                }
            }
        }
    }
}

/// 小徽标。
struct Tag: View {
    let text: String
    var color: Color = OMColors.secondaryText

    init(_ text: String, color: Color = OMColors.secondaryText) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(OMFonts.caption)
            .foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(color.opacity(0.12), in: Capsule())
    }
}

/// 列表 + 详情的左右分栏。
struct ListDetail<List: View, Detail: View>: View {
    @ViewBuilder var list: List
    @ViewBuilder var detail: Detail

    var body: some View {
        // 固定宽度的列表列 + 自适应详情:不使用嵌套的 HSplitView(嵌在设置的 NavigationSplitView 内会破坏侧栏宽度)
        HStack(spacing: 0) {
            list.frame(width: 320)
            Divider()
            detail.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// 空状态占位。
struct EmptyHint: View {
    let icon: String
    let title: String
    var message: String?

    var body: some View {
        VStack(spacing: 8) {
            Image.om(icon, size: 28).foregroundStyle(OMColors.tertiaryText)
            Text(verbatim: omLocalized(title)).font(OMFonts.title)
            if let message { Text(verbatim: omLocalized(message)).font(OMFonts.small).foregroundStyle(OMColors.secondaryText).multilineTextAlignment(.center) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

/// 表单行:左侧标签 + 右侧控件。
struct FormRow<Content: View>: View {
    let label: String
    var hint: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(verbatim: omLocalized(label)).font(OMFonts.small).foregroundStyle(OMColors.secondaryText).frame(width: 84, alignment: .trailing)
                content
            }
            if let hint {
                Text(verbatim: omLocalized(hint)).font(OMFonts.caption).foregroundStyle(OMColors.tertiaryText).padding(.leading, 94)
            }
        }
    }
}

/// 带校验提示的弹窗底栏:取消 / 确认。
struct SheetFooter: View {
    let problems: [String]
    let confirmTitle: String
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(problems, id: \.self) { problem in
                Label(problem, om: "exclamationmark.circle").font(OMFonts.small).foregroundStyle(OMColors.warning)
            }
            HStack {
                Spacer()
                Button("取消", action: onCancel).keyboardShortcut(.cancelAction)
                Button(confirmTitle, action: onConfirm)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!problems.isEmpty)
            }
        }
    }
}

/// 把 `KEY=VALUE` 多行文本解析为字典。
func parseKeyValues(_ text: String, separator: Character) -> [String: String] {
    var result: [String: String] = [:]
    for line in text.split(separator: "\n") {
        guard let index = line.firstIndex(of: separator) else { continue }
        let key = line[..<index].trimmingCharacters(in: .whitespaces)
        let value = line[line.index(after: index)...].trimmingCharacters(in: .whitespaces)
        if !key.isEmpty { result[key] = value }
    }
    return result
}

/// 把字典渲染为多行文本。
func renderKeyValues(_ dictionary: [String: String], separator: String) -> String {
    dictionary.keys.sorted().map { "\($0)\(separator)\(dictionary[$0] ?? "")" }.joined(separator: "\n")
}
