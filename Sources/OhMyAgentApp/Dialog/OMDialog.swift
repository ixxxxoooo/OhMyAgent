// @author ixxxxoooo
// 自绘模态对话框 `OMDialog`:替代 NSAlert,样式与 Cursor 一致(居中圆角卡片 + 遮罩 + 标题/说明/输入框/按钮行)。
// 同步模态(`NSApp.runModal`),调用点无需改成异步;`OMModal.run` 还可承载任意 SwiftUI 内容(编辑工作区、更换图标等)。

import AppKit
import ChatKit
import DesignSystem
import IconKit
import SwiftUI

// MARK: - 模态面板

/// 模态句柄:内容里调用 `finish` 结束模态。
@MainActor
final class OMModalHandle {
    fileprivate var onFinish: ((Int) -> Void)?
    /// 结束模态并返回结果码(约定:0 为确认/第一个按钮,-1 为取消)。
    func finish(_ code: Int = 0) { onFinish?(code) }
}

/// 无边框可成为 key 的模态面板;Esc 触发取消。
private final class OMModalPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// 模态呈现器。
@MainActor
enum OMModal {
    /// 卡片四周留给阴影的边距
    private static let inset: CGFloat = 28

    /// 以模态方式展示自定义内容,阻塞直到 `handle.finish` 被调用。
    /// - Parameters:
    ///   - width: 卡片宽度
    ///   - content: 内容(收到句柄用于关闭)
    /// - Returns: 结果码(取消为 -1)
    @discardableResult
    static func run<Content: View>(width: CGFloat = 400, @ViewBuilder content: (OMModalHandle) -> Content) -> Int {
        let handle = OMModalHandle()
        let card = content(handle)
            .frame(width: width)
            .omGlassCard(cornerRadius: OMRadius.modal)
            .omFloatingShadow(cornerRadius: OMRadius.modal, yOffset: 10)
            .padding(inset)
        let hosting = NSHostingView(rootView: card)
        let size = hosting.fittingSize
        let parent = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first { $0.isVisible && !($0 is NSPanel) }

        let panel = OMModalPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.contentView = hosting
        if let parent {
            let frame = parent.frame
            let origin = NSPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2 + frame.height * 0.08)
            panel.setFrameOrigin(origin)
        } else {
            panel.center()
        }

        // 遮罩窗口:覆盖父窗口,不接收事件
        var scrim: NSWindow?
        if let parent {
            let cover = NSWindow(contentRect: parent.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            cover.isOpaque = false
            cover.backgroundColor = NSColor(OMColors.scrim)
            cover.ignoresMouseEvents = true
            cover.hasShadow = false
            cover.isReleasedWhenClosed = false
            parent.addChildWindow(cover, ordered: .above)
            scrim = cover
        }

        var result = -1
        handle.onFinish = { code in
            result = code
            NSApp.stopModal()
        }
        panel.onCancel = { handle.finish(-1) }
        parent?.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        NSApp.runModal(for: panel)
        parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        if let scrim { parent?.removeChildWindow(scrim); scrim.orderOut(nil) }
        parent?.makeKeyAndOrderFront(nil)
        return result
    }
}

// MARK: - 标准对话框

/// 对话框按钮。
struct OMDialogButton {
    /// 按钮角色。
    enum Role {
        /// 取消(靠左,Esc 触发)
        case cancel
        /// 普通次按钮
        case normal
        /// 主按钮(回车触发)
        case primary
        /// 危险主按钮(回车触发,红色文字)
        case destructive
    }

    var title: String
    var role: Role

    /// 取消按钮。
    static func cancel(_ title: String = String(localized: "取消")) -> OMDialogButton { OMDialogButton(title: title, role: .cancel) }
    /// 主按钮。
    static func primary(_ title: String) -> OMDialogButton { OMDialogButton(title: title, role: .primary) }
    /// 普通按钮。
    static func normal(_ title: String) -> OMDialogButton { OMDialogButton(title: title, role: .normal) }
    /// 危险主按钮。
    static func destructive(_ title: String) -> OMDialogButton { OMDialogButton(title: title, role: .destructive) }
}

/// 对话框的单行输入框配置。
struct OMDialogField {
    var placeholder = ""
    var initial = ""
    /// 校验:返回错误文案表示不合法(此时主按钮不可用并显示错误)
    var validate: ((String) -> String?)?
}

/// 标准对话框入口。
@MainActor
enum OMDialog {
    /// 展示对话框并返回被点击按钮的下标与输入文本。
    /// - Parameters:
    ///   - title: 标题
    ///   - message: 说明(可空)
    ///   - icon: 标题左侧图标(Lucide 语义名,可空)
    ///   - field: 单行输入框配置(可空)
    ///   - buttons: 按钮(显示顺序:取消靠左,其余靠右依次排列)
    /// - Returns: 下标为 `buttons` 中的位置;Esc 返回取消按钮的下标(无取消按钮为 -1)
    static func show(title: String, message: String = "", icon: String? = nil, field: OMDialogField? = nil, buttons: [OMDialogButton]) -> (index: Int, text: String) {
        let state = OMDialogTextState(text: field?.initial ?? "")
        let code = OMModal.run(width: 400) { handle in
            OMDialogCard(title: title, message: message, icon: icon, field: field, buttons: buttons, state: state) { handle.finish($0) }
        }
        let cancelIndex = buttons.firstIndex { $0.role == .cancel } ?? -1
        return (code == -1 ? cancelIndex : code, state.text)
    }

    /// 确认框。
    /// - Parameters:
    ///   - title: 标题
    ///   - message: 说明
    ///   - confirmTitle: 确认按钮文案
    ///   - destructive: 是否危险操作(红色)
    /// - Returns: 是否确认
    static func confirm(title: String, message: String = "", confirmTitle: String, destructive: Bool = false) -> Bool {
        let confirm: OMDialogButton = destructive ? .destructive(confirmTitle) : .primary(confirmTitle)
        return show(title: title, message: message, icon: destructive ? "triangle-alert" : nil, buttons: [.cancel(), confirm]).index == 1
    }

    /// 单行输入框。
    /// - Returns: 去除首尾空白后的输入;取消或为空返回 nil
    static func prompt(title: String, message: String = "", initial: String = "", placeholder: String = "",
                       confirmTitle: String = String(localized: "确定"), validate: ((String) -> String?)? = nil) -> String? {
        let result = show(title: title, message: message, field: OMDialogField(placeholder: placeholder, initial: initial, validate: validate),
                          buttons: [.cancel(), .primary(confirmTitle)])
        guard result.index == 1 else { return nil }
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// 提示框(只有「好」)。
    static func alert(title: String, message: String = "", isError: Bool = false) {
        _ = show(title: title, message: message, icon: isError ? "triangle-alert" : nil, buttons: [.primary(String(localized: "好"))])
    }
}

/// 输入文本的共享状态(对话框关闭后读取)。
@MainActor
@Observable
final class OMDialogTextState {
    var text: String
    init(text: String) { self.text = text }
}

/// 标准对话框卡片。
private struct OMDialogCard: View {
    let title: String
    let message: String
    let icon: String?
    let field: OMDialogField?
    let buttons: [OMDialogButton]
    @Bindable var state: OMDialogTextState
    let finish: (Int) -> Void
    @FocusState private var fieldFocused: Bool

    /// 说明区可用宽度(卡片宽 400 减左右内边距)
    private static let messageWidth: CGFloat = 360
    /// 说明区最大高度,超出后上下滚动
    private static let messageMaxHeight: CGFloat = 260

    /// 说明正文:以「• 」开头的行渲染为悬挂缩进的列表项;内容过长时限高并可滚动。
    @ViewBuilder
    private var messageBody: some View {
        let list = OMDialogMessageList(message: message)
        let natural = NSHostingView(rootView: list.frame(width: Self.messageWidth, alignment: .leading)).fittingSize.height
        if natural > Self.messageMaxHeight {
            ScrollView(.vertical) { list }
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: Self.messageMaxHeight)
        } else {
            list
        }
    }

    private var error: String? { field?.validate?(state.text.trimmingCharacters(in: .whitespacesAndNewlines)) }
    private var isEmptyInput: Bool { field != nil && state.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var defaultIndex: Int? { buttons.firstIndex { $0.role == .primary || $0.role == .destructive } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let icon { Image.om(icon, size: 16).foregroundStyle(OMColors.secondaryText) }
                Text(verbatim: title).font(OMFonts.title).foregroundStyle(OMColors.primaryText).fixedSize(horizontal: false, vertical: true)
            }
            if !message.isEmpty {
                messageBody
            }
            if let field {
                VStack(alignment: .leading, spacing: 4) {
                    TextField(field.placeholder, text: $state.text)
                        .textFieldStyle(.plain)
                        .font(OMFonts.body)
                        .focused($fieldFocused)
                        .padding(.horizontal, 8)
                        .frame(height: 30)
                        .background(OMColors.subtleFill, in: RoundedRectangle(cornerRadius: OMRadius.control, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: OMRadius.control, style: .continuous).strokeBorder(error == nil ? OMColors.hairline : OMColors.danger, lineWidth: 0.5))
                        .onSubmit { submitDefault() }
                        .accessibilityLabel(title)
                    if let error, !state.text.isEmpty {
                        Text(verbatim: error).font(OMFonts.caption).foregroundStyle(OMColors.danger)
                    }
                }
            }
            HStack(spacing: 8) {
                ForEach(Array(buttons.enumerated().filter { $0.element.role == .cancel }), id: \.offset) { index, button in
                    Button(button.title) { finish(index) }.buttonStyle(OMButtonStyle(.secondary, size: .regular))
                }
                Spacer(minLength: 16)
                ForEach(Array(buttons.enumerated().filter { $0.element.role != .cancel }), id: \.offset) { index, button in
                    actionButton(index, button)
                }
            }
            .padding(.top, 4)
        }
        .padding(20)
        .task {
            try? await Task.sleep(for: .milliseconds(40))
            if field != nil { fieldFocused = true }
        }
    }

    @ViewBuilder
    private func actionButton(_ index: Int, _ button: OMDialogButton) -> some View {
        let disabled = (button.role == .primary || button.role == .destructive) && field != nil && (isEmptyInput || error != nil)
        let kind: OMButtonStyle.Kind = {
            switch button.role {
            case .primary: return .primary
            case .destructive: return .destructive
            default: return .secondary
            }
        }()
        let base = Button(button.title) { finish(index) }
            .buttonStyle(OMButtonStyle(kind, size: .regular))
            .disabled(disabled)
        if index == defaultIndex { base.keyboardShortcut(.defaultAction) } else { base }
    }

    /// 回车:触发默认按钮(输入不合法时忽略)。
    private func submitDefault() {
        guard let index = defaultIndex, !isEmptyInput, error == nil else { return }
        finish(index)
    }
}

/// 对话框说明的逐行排版:「• 」开头的行用悬挂缩进,其余行为普通段落。
private struct OMDialogMessageList: View {
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(message.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, line in
                if line.hasPrefix("• ") {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(verbatim: "•")
                        Text(verbatim: String(line.dropFirst(2))).fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text(verbatim: String(line)).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(OMFonts.small)
        .foregroundStyle(OMColors.secondaryText)
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }
}
