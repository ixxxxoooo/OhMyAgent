// @author ixxxxoooo
// 终端面板的多终端仓库:每个项目根一份 `TerminalPanelState`,持久化到 UserDefaults;
// 进程与渲染仍由 `TerminalStore` 按实例 id 持有(切换/隐藏不结束进程,关闭实例才结束)。

import Foundation
import Observation
import OMLog
import WorkbenchKit

@MainActor
@Observable
final class TerminalPanelStore {
    static let shared = TerminalPanelStore()

    /// 持久化键
    static let defaultsKey = "terminal.panel.states"
    /// 最多保留多少个项目根的状态
    private static let maxRoots = 40

    private(set) var states: [String: TerminalPanelState]
    @ObservationIgnored private let defaults: UserDefaults

    /// - Parameter defaults: 持久化存储(测试可注入)
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var loaded: [String: TerminalPanelState] = [:]
        if let data = defaults.data(forKey: Self.defaultsKey) {
            do {
                loaded = try JSONDecoder().decode([String: TerminalPanelState].self, from: data)
                for key in loaded.keys { loaded[key]?.normalize() }
            } catch {
                Log.ui.warning("终端面板状态解码失败,已重置", ["error": "\(error)"])
            }
        }
        states = loaded
    }

    /// 某项目根的状态(没有则新建,不写盘)。
    /// - Parameter root: 项目根目录
    func state(for root: String) -> TerminalPanelState {
        states[root] ?? TerminalPanelState(root: root)
    }

    /// 新建终端并激活。
    /// - Parameters:
    ///   - root: 项目根目录
    ///   - name: 初始名称(nil 或空白沿用自动标题)
    ///   - prefs: 终端偏好(决定起始目录)
    /// - Returns: 新实例;达到上限返回 nil
    @discardableResult
    func addTerminal(root: String, name: String? = nil, prefs: TerminalPrefs = .load()) -> TerminalInstance? {
        var state = state(for: root)
        guard let instance = state.add(title: name) else { return nil }
        TerminalStore.shared.register(id: instance.id, directory: prefs.startDirectoryPath(project: root))
        commit(state, for: root)
        Log.ui.info("新建终端实例", ["id": instance.id, "count": "\(state.instances.count)"])
        return instance
    }

    /// 激活指定终端。
    func activate(_ id: String, root: String) {
        var state = state(for: root)
        state.activate(id)
        commit(state, for: root)
    }

    /// 循环切换终端。
    /// - Parameters:
    ///   - step: 1 下一个,-1 上一个
    ///   - root: 项目根目录
    func cycle(_ step: Int, root: String) {
        var state = state(for: root)
        state.cycle(step)
        commit(state, for: root)
    }

    /// 关闭终端并结束其进程。
    /// - Returns: 关闭结果(`.closedLast` 时调用方应隐藏面板)
    @discardableResult
    func close(_ id: String, root: String) -> TerminalCloseResult {
        var state = state(for: root)
        let result = state.close(id)
        guard result != .unknown else { return result }
        TerminalStore.shared.remove(id)
        commit(state, for: root)
        return result
    }

    /// 关闭除指定终端外的其他终端。
    func closeOthers(keeping id: String, root: String) {
        var state = state(for: root)
        let closed = state.closeOthers(keeping: id)
        for other in closed { TerminalStore.shared.remove(other) }
        commit(state, for: root)
    }

    /// 拖动排序:把终端移到另一个终端之前。
    /// - Parameters:
    ///   - id: 被移动的终端
    ///   - target: 目标终端;nil 表示移到末尾
    ///   - root: 项目根目录
    func move(_ id: String, before target: String?, root: String) {
        var state = state(for: root)
        let before = state.instances.map(\.id)
        state.move(id, before: target)
        guard state.instances.map(\.id) != before else { return }
        commit(state, for: root)
    }

    /// 重命名终端。
    func rename(_ id: String, to title: String, root: String) {
        var state = state(for: root)
        state.rename(id, to: title)
        commit(state, for: root)
    }

    /// 实例标题:自定义名称 > shell 上报的标题 > 「终端 N」。
    /// - Parameter instance: 终端实例
    func title(of instance: TerminalInstance) -> String {
        if let custom = instance.customTitle { return custom }
        if let reported = TerminalStore.shared.controllers[instance.id]?.title, !reported.isEmpty { return reported }
        return String(localized: "终端") + (instance.serial > 1 ? " \(instance.serial)" : "")
    }

    /// 写回状态并持久化(只有一个初始实例且未改动的状态不落盘)。
    private func commit(_ state: TerminalPanelState, for root: String) {
        states[root] = state
        if states.count > Self.maxRoots, let stale = states.keys.first(where: { $0 != root }) { states[stale] = nil }
        do {
            defaults.set(try JSONEncoder().encode(states), forKey: Self.defaultsKey)
        } catch {
            Log.ui.warning("终端面板状态保存失败", ["error": "\(error)"])
        }
    }
}
