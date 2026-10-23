// @author ixxxxoooo
// 表格预览(xlsx / CSV)的查找:状态模型、查找条与菜单路由。
// ⌘F / ⌘G 先交给代码编辑器;没有编辑器响应时,经通知让当前可见的表格预览打开查找条。

import AppKit
import DesignSystem
import IconKit
import Observation
import SpreadsheetKit
import SwiftUI

/// 表格查找的菜单动作。
enum TableFindAction: String {
    case show, next, previous
}

extension Notification.Name {
    /// 菜单 ⌘F / ⌘G / ⇧⌘G 在没有代码编辑器响应时发出,`userInfo["action"]` 为 `TableFindAction.rawValue`。
    static let omTableFind = Notification.Name("OhMyAgent.tableFind")
}

enum TableFindRouter {
    /// 通知当前可见的表格预览执行查找动作。
    /// - Parameter action: 查找动作
    @MainActor
    static func post(_ action: TableFindAction) {
        NotificationCenter.default.post(name: .omTableFind, object: nil, userInfo: ["action": action.rawValue])
    }

    /// 解析通知里的动作。
    static func action(from notification: Notification) -> TableFindAction? {
        (notification.userInfo?["action"] as? String).flatMap(TableFindAction.init(rawValue:))
    }
}

/// 一个表格预览的查找状态。
@MainActor
@Observable
final class TableFindState {
    var isOpen = false
    var query = ""
    /// 匹配列表(行优先)与其集合形式(绘制高亮用)
    private(set) var matches: [TableMatch] = []
    private(set) var matchSet: Set<TableMatch> = []
    /// 当前匹配在 `matches` 里的下标
    private(set) var index = 0
    /// 递增以请求查找框获得焦点
    private(set) var focusToken = 0

    /// 当前匹配。
    var current: TableMatch? { matches.indices.contains(index) ? matches[index] : nil }

    /// 打开查找条并聚焦输入框。
    func show() {
        isOpen = true
        focusToken += 1
    }

    /// 关闭查找条并清除高亮。
    func close() {
        isOpen = false
        setMatches([], keeping: nil)
    }

    /// 更新匹配列表;尽量保持原来选中的那一处,否则回到第一处。
    func setMatches(_ new: [TableMatch], keeping previous: TableMatch?) {
        matches = new
        matchSet = Set(new)
        if let previous, let found = new.firstIndex(of: previous) { index = found } else { index = 0 }
    }

    /// 跳到下一处/上一处(循环)。
    func step(forward: Bool) {
        guard !matches.isEmpty else { return }
        index = (index + (forward ? 1 : matches.count - 1)) % matches.count
    }

    /// 响应菜单动作(未打开时先打开)。
    func handle(_ action: TableFindAction) {
        switch action {
        case .show: show()
        case .next: if isOpen { step(forward: true) } else { show() }
        case .previous: if isOpen { step(forward: false) } else { show() }
        }
    }
}

/// 查找条:输入框、`第几处/共几处`、上一处/下一处、关闭。回车下一处,⇧回车上一处,Esc 关闭。
struct TableFindBar: View {
    let state: TableFindState
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var state = state
        HStack(spacing: 8) {
            Image.om("search", size: 12).foregroundStyle(OMColors.tertiaryText)
            TextField("在表格中查找", text: $state.query)
                .textFieldStyle(.plain)
                .font(OMFonts.small)
                .focused($focused)
                .onKeyPress(.return, phases: .down) { press in
                    state.step(forward: !press.modifiers.contains(.shift))
                    return .handled
                }
                .onKeyPress(.escape) { state.close(); return .handled }
            Text(summary)
                .font(OMFonts.caption.monospacedDigit())
                .foregroundStyle(state.matches.isEmpty && !state.query.isEmpty ? OMColors.danger : OMColors.tertiaryText)
            Button { state.step(forward: false) } label: { Image.om("chevron-up", size: 12) }
                .buttonStyle(.omIcon).disabled(state.matches.isEmpty)
                .omTooltip("上一处").accessibilityLabel("上一处")
            Button { state.step(forward: true) } label: { Image.om("chevron-down", size: 12) }
                .buttonStyle(.omIcon).disabled(state.matches.isEmpty)
                .omTooltip("下一处").accessibilityLabel("下一处")
            Button { state.close() } label: { Image.om("x", size: 12) }
                .buttonStyle(.omIcon)
                .omTooltip("关闭查找").accessibilityLabel("关闭查找")
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .task(id: state.focusToken) {
            // 先让持有焦点的控件放手,再把焦点交给输入框;输入框出现晚一帧时补一次
            NSApp.keyWindow?.makeFirstResponder(nil)
            focused = true
            try? await Task.sleep(for: .milliseconds(60))
            focused = true
        }
    }

    private var summary: String {
        if state.query.trimmingCharacters(in: .whitespaces).isEmpty { return "" }
        if state.matches.isEmpty { return String(localized: "无结果") }
        let total = state.matches.count >= TableSearch.maxMatches ? "\(TableSearch.maxMatches.formatted())+" : state.matches.count.formatted()
        return "\(state.index + 1)/\(total)"
    }
}
