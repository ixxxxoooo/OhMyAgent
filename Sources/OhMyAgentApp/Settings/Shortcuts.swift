// @author ixxxxoooo
// 快捷键:可自定义的动作表,冲突检测,导入导出。菜单与按钮从这里读取,修改后立即生效。

import AppKit
import Observation
import SwiftUI

/// 可自定义的动作。
enum ShortcutAction: String, CaseIterable, Identifiable {
    case newConversation, openWorkspace, extensions, send
    case toggleSidebar, toggleInspector, togglePanel
    case saveFile, hubSearch, quickOpen, commandPalette, globalSearch, newTerminal
    case closeTab, reopenTab, nextTab, previousTab
    var id: String { rawValue }

    var title: String {
        switch self {
        case .newConversation: return String(localized: "新对话")
        case .openWorkspace: return String(localized: "打开项目")
        case .extensions: return String(localized: "工具与扩展")
        case .send: return String(localized: "发送消息")
        case .toggleSidebar: return String(localized: "切换项目栏")
        case .toggleInspector: return String(localized: "切换工具栏")
        case .togglePanel: return String(localized: "切换终端面板")
        case .saveFile: return String(localized: "保存文件")
        case .hubSearch: return String(localized: "搜索")
        case .quickOpen: return String(localized: "快速打开文件")
        case .commandPalette: return String(localized: "命令面板")
        case .globalSearch: return String(localized: "在文件中搜索")
        case .newTerminal: return String(localized: "新建终端标签")
        case .closeTab: return String(localized: "关闭标签")
        case .reopenTab: return String(localized: "重新打开已关闭的标签")
        case .nextTab: return String(localized: "下一个标签")
        case .previousTab: return String(localized: "上一个标签")
        }
    }

    /// 默认快捷键。
    var defaultBinding: ShortcutBinding {
        switch self {
        case .newConversation: return ShortcutBinding(key: "n", modifiers: ["command", "shift"])
        case .openWorkspace: return ShortcutBinding(key: "o", modifiers: ["command"])
        case .extensions: return ShortcutBinding(key: "e", modifiers: ["command", "shift"])
        case .send: return ShortcutBinding(key: "return", modifiers: ["command"])
        case .toggleSidebar: return ShortcutBinding(key: "b", modifiers: ["command"])
        case .toggleInspector: return ShortcutBinding(key: "b", modifiers: ["command", "option"])
        case .togglePanel: return ShortcutBinding(key: "j", modifiers: ["command"])
        case .saveFile: return ShortcutBinding(key: "s", modifiers: ["command"])
        case .hubSearch: return ShortcutBinding(key: "k", modifiers: ["command"])
        case .quickOpen: return ShortcutBinding(key: "p", modifiers: ["command"])
        case .commandPalette: return ShortcutBinding(key: "p", modifiers: ["command", "shift"])
        case .globalSearch: return ShortcutBinding(key: "f", modifiers: ["command", "shift"])
        case .newTerminal: return ShortcutBinding(key: "`", modifiers: ["control", "shift"])
        case .closeTab: return ShortcutBinding(key: "w", modifiers: ["command"])
        case .reopenTab: return ShortcutBinding(key: "t", modifiers: ["command", "shift"])
        case .nextTab: return ShortcutBinding(key: "tab", modifiers: ["control"])
        case .previousTab: return ShortcutBinding(key: "tab", modifiers: ["control", "shift"])
        }
    }
}

/// 一个快捷键组合。
struct ShortcutBinding: Equatable, Codable, Sendable {
    var key: String
    var modifiers: [String]

    var eventModifiers: EventModifiers {
        var result: EventModifiers = []
        if modifiers.contains("command") { result.insert(.command) }
        if modifiers.contains("shift") { result.insert(.shift) }
        if modifiers.contains("option") { result.insert(.option) }
        if modifiers.contains("control") { result.insert(.control) }
        return result
    }

    var keyEquivalent: KeyEquivalent {
        switch key {
        case "return": return .return
        case "tab": return .tab
        default: return KeyEquivalent(key.first ?? " ")
        }
    }

    var keyboardShortcut: KeyboardShortcut { KeyboardShortcut(keyEquivalent, modifiers: eventModifiers) }

    /// 例如 ⇧⌘N。
    var display: String {
        var text = ""
        if modifiers.contains("control") { text += "⌃" }
        if modifiers.contains("option") { text += "⌥" }
        if modifiers.contains("shift") { text += "⇧" }
        if modifiers.contains("command") { text += "⌘" }
        return text + (key == "return" ? "↩" : key == "tab" ? "⇥" : key.uppercased())
    }

    /// 从按键事件构造;没有 ⌘/⌃/⌥ 修饰键时返回 nil(避免吞掉普通输入)。
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard flags.contains(.command) || flags.contains(.control) || flags.contains(.option) else { return nil }
        let name: String
        if event.keyCode == 36 || event.keyCode == 76 { name = "return" }
        else if event.keyCode == 48 { name = "tab" }
        else if let character = event.charactersIgnoringModifiers?.lowercased(), character.count == 1, character.unicodeScalars.first!.value >= 0x20 { name = character }
        else { return nil }
        var list: [String] = []
        if flags.contains(.command) { list.append("command") }
        if flags.contains(.shift) { list.append("shift") }
        if flags.contains(.option) { list.append("option") }
        if flags.contains(.control) { list.append("control") }
        key = name
        modifiers = list
    }

    init(key: String, modifiers: [String]) {
        self.key = key
        self.modifiers = modifiers
    }
}

/// 快捷键存储。
@MainActor
@Observable
final class ShortcutStore {
    static let shared = ShortcutStore()

    private(set) var overrides: [String: ShortcutBinding] = [:]

    /// 系统保留,不允许占用。
    static let reserved: [ShortcutBinding] = [
        ShortcutBinding(key: "q", modifiers: ["command"]),
        ShortcutBinding(key: "h", modifiers: ["command"]), ShortcutBinding(key: "m", modifiers: ["command"]),
        ShortcutBinding(key: ",", modifiers: ["command"]), ShortcutBinding(key: "c", modifiers: ["command"]),
        ShortcutBinding(key: "v", modifiers: ["command"]), ShortcutBinding(key: "x", modifiers: ["command"]),
        ShortcutBinding(key: "a", modifiers: ["command"]), ShortcutBinding(key: "z", modifiers: ["command"]),
    ]

    private init() {
        for action in ShortcutAction.allCases {
            if let data = UserDefaults.standard.data(forKey: Self.key(action)), let binding = try? JSONDecoder().decode(ShortcutBinding.self, from: data) {
                overrides[action.rawValue] = binding
            }
        }
    }

    private static func key(_ action: ShortcutAction) -> String { "shortcut.\(action.rawValue)" }

    /// 当前生效的组合。
    func binding(for action: ShortcutAction) -> ShortcutBinding { overrides[action.rawValue] ?? action.defaultBinding }

    /// SwiftUI 快捷键。
    func shortcut(for action: ShortcutAction) -> KeyboardShortcut { binding(for: action).keyboardShortcut }

    /// 检测冲突:返回与之冲突的动作名或"系统保留"。
    func conflict(for binding: ShortcutBinding, excluding action: ShortcutAction) -> String? {
        if Self.reserved.contains(binding) { return String(localized: "系统保留") }
        return ShortcutAction.allCases.first { $0 != action && self.binding(for: $0) == binding }?.title
    }

    /// 设置;冲突时返回原因且不修改。
    @discardableResult
    func set(_ binding: ShortcutBinding, for action: ShortcutAction) -> String? {
        if let reason = conflict(for: binding, excluding: action) { return String(localized: "与「\(reason)」冲突") }
        if binding == action.defaultBinding {
            reset(action)
        } else {
            overrides[action.rawValue] = binding
            UserDefaults.standard.set(try? JSONEncoder().encode(binding), forKey: Self.key(action))
        }
        return nil
    }

    /// 恢复单个默认。
    func reset(_ action: ShortcutAction) {
        overrides[action.rawValue] = nil
        UserDefaults.standard.removeObject(forKey: Self.key(action))
    }

    /// 导出为 JSON(动作 → 组合)。
    func exportJSON() -> Data? {
        let all = Dictionary(uniqueKeysWithValues: ShortcutAction.allCases.map { ($0.rawValue, binding(for: $0)) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(all)
    }

    /// 导入 JSON;跳过未知动作与冲突项。
    /// - Returns: 成功导入数量与被跳过的说明
    func importJSON(_ data: Data) -> (imported: Int, skipped: [String]) {
        guard let decoded = try? JSONDecoder().decode([String: ShortcutBinding].self, from: data) else { return (0, [String(localized: "文件格式不正确")]) }
        var imported = 0
        var skipped: [String] = []
        for (name, binding) in decoded {
            guard let action = ShortcutAction(rawValue: name) else { skipped.append(String(localized: "未知动作 \(name)")); continue }
            if let reason = set(binding, for: action) { skipped.append("\(action.title):\(reason)") } else { imported += 1 }
        }
        return (imported, skipped)
    }
}
