// @author ixxxxoooo
// 窗口上下文:菜单与快捷键需要知道「当前键盘窗口」是 Agent 窗口还是某个 IDE 窗口,
// 以便把 ⌘B / ⌘J / ⌘W 等命令派发给正确的窗口(而不是一律作用在 Agent 工作台上)。

import AppKit
import IDEKit
import Observation

/// 当前键盘窗口的种类。
enum WindowContextKind: Equatable {
    /// Agent 窗口(或其他非 IDE 窗口)
    case agent
    /// 某个 IDE 窗口
    case ide(UUID)
}

/// 窗口上下文的观察入口。菜单 `Commands` 读取 `kind` 即可随键盘窗口切换自动刷新。
@MainActor
@Observable
final class WindowContext {
    static let shared = WindowContext()

    /// 当前键盘窗口的种类
    private(set) var kind: WindowContextKind = .agent

    /// 当前是否位于 IDE 窗口。
    var isIDE: Bool {
        if case .ide = kind { return true }
        return false
    }

    /// 当前 IDE 窗口的模型(不在 IDE 窗口时为 nil)。
    var ideModel: IDEWindowModel? {
        guard case .ide(let id) = kind else { return nil }
        return IDEWindowManager.shared.registry.window(id: id)
    }

    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private init() {}

    /// 开始监听窗口成为键盘窗口的通知(幂等)。
    func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
            guard let window = note.object as? NSWindow else { return }
            MainActor.assumeIsolated { WindowContext.shared.windowBecameKey(window) }
        })
    }

    /// 某个窗口成为键盘窗口:IDE 窗口(含其子窗口/表单)→ IDE;其他可成为主窗口的窗口 → Agent;
    /// 面板、提示等辅助窗口不改变上下文。
    /// - Parameter window: 成为键盘窗口的窗口
    func windowBecameKey(_ window: NSWindow) {
        var cursor: NSWindow? = window
        while let current = cursor {
            if let model = IDEWindowManager.shared.model(for: current) {
                update(.ide(model.id))
                return
            }
            cursor = current.parent ?? current.sheetParent
        }
        if window.canBecomeMain { update(.agent) }
    }

    private func update(_ new: WindowContextKind) {
        if kind != new { kind = new }
    }
}
