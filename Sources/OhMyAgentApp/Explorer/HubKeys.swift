// @author ixxxxoooo
// 中央搜索窗的键盘处理:把底部提示里的 ↑↓ / ↵ / ⇥ / esc 落实为真正生效的按键。
// SwiftUI 的 `onKeyPress` 在文本框里会被字段编辑器抢先处理(⇥ 会直接移走焦点),
// 所以改用窗口级本地事件监视器,在事件进入字段编辑器之前解析。

import AppKit

/// 搜索窗支持的键盘指令。
enum HubKeyCommand: Equatable {
    /// 移动选中项(+1 下一项,-1 上一项)
    case move(Int)
    /// 切换分类(+1 下一个,-1 上一个)
    case switchSegment(Int)
    /// 执行当前选中项
    case submit
    /// 关闭搜索窗
    case dismiss
}

/// 按键 → 指令的纯函数解析(便于测试)。
enum HubKeyResolver {
    /// 常用键码(ANSI 键盘布局无关的虚拟键码)。
    enum Code {
        static let returnKey: UInt16 = 36
        static let tab: UInt16 = 48
        static let escape: UInt16 = 53
        static let keypadEnter: UInt16 = 76
        static let downArrow: UInt16 = 125
        static let upArrow: UInt16 = 126
        /// ⌃N / ⌃P(Emacs 风格上下移动)
        static let keyN: UInt16 = 45
        static let keyP: UInt16 = 35
    }

    /// 解析一次按键。
    /// - Parameters:
    ///   - keyCode: 虚拟键码
    ///   - modifiers: 修饰键(只看 ⌘⌃⌥⇧)
    ///   - composing: 输入法正在组字(此时方向键/回车/Esc 属于输入法,必须放行)
    /// - Returns: 对应指令;不处理时为 nil(事件照常传递)
    static func resolve(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, composing: Bool) -> HubKeyCommand? {
        guard !composing else { return nil }
        let flags = modifiers.intersection([.command, .control, .option, .shift])
        switch keyCode {
        case Code.downArrow where flags.isEmpty: return .move(1)
        case Code.upArrow where flags.isEmpty: return .move(-1)
        case Code.keyN where flags == .control: return .move(1)
        case Code.keyP where flags == .control: return .move(-1)
        case Code.tab where flags.isEmpty: return .switchSegment(1)
        case Code.tab where flags == .shift: return .switchSegment(-1)
        case Code.returnKey where flags.isEmpty, Code.keypadEnter where flags.isEmpty: return .submit
        case Code.escape where flags.isEmpty: return .dismiss
        default: return nil
        }
    }
}

/// 搜索窗打开期间的本地键盘监视器(只在 `isPresented` 时安装)。
@MainActor
final class HubKeyMonitor {
    private var token: Any?

    /// 安装监视器(幂等)。
    /// - Parameter handler: 收到指令时调用,返回 true 表示已处理(事件被吞掉)
    func install(handler: @escaping @MainActor (HubKeyCommand) -> Bool) {
        guard token == nil else { return }
        token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let command = MainActor.assumeIsolated { () -> HubKeyCommand? in
                let composing = (NSApp.keyWindow?.firstResponder as? NSTextView)?.hasMarkedText() ?? false
                return HubKeyResolver.resolve(keyCode: event.keyCode, modifiers: event.modifierFlags, composing: composing)
            }
            guard let command else { return event }
            let handled = MainActor.assumeIsolated { handler(command) }
            return handled ? nil : event
        }
    }

    /// 移除监视器(幂等)。
    func remove() {
        if let token { NSEvent.removeMonitor(token) }
        token = nil
    }
}
