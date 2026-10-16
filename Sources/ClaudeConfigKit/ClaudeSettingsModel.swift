// @author ixxxxoooo
// 供设置页使用的可观察设置模型:按层读写 settings.json,监听文件变化并自动刷新(热更新)。

import Foundation
import Observation

/// 可观察的 Claude 设置模型。
@MainActor
@Observable
public final class ClaudeSettingsModel {
    /// 每次外部或内部变化后递增,视图读取它即可建立依赖。
    public private(set) var revision = 0
    /// 当前编辑的设置层
    public var scope: ConfigScope = .user { didSet { revision += 1 } }
    public var lastError: String?

    public let paths: ClaudePaths
    @ObservationIgnored private var watcher: ConfigWatcher?

    /// - Parameter paths: 配置路径
    public init(paths: ClaudePaths) { self.paths = paths }

    /// 是否可以写当前层(项目/本地层需要工作区)。
    public var canWriteCurrentScope: Bool { scope == .user || paths.workspace != nil }

    /// 开始监听文件变化。
    public func start() {
        guard watcher == nil else { return }
        let watcher = ConfigWatcher(paths: paths) { [weak self] in
            Task { @MainActor in self?.revision += 1 }
        }
        watcher.start()
        self.watcher = watcher
    }

    /// 停止监听。
    public func stop() {
        watcher?.stop()
        watcher = nil
    }

    private var store: SettingsStore { SettingsStore(paths: paths) }

    // MARK: - 读取(访问 revision 以建立观察依赖)

    /// 当前层的值。
    public func value(_ path: [String]) -> Any? {
        _ = revision
        return store.value(path, in: scope)
    }

    /// 字符串值。
    public func string(_ path: [String]) -> String? { value(path) as? String }
    /// 布尔值。
    public func bool(_ path: [String]) -> Bool? { value(path) as? Bool }
    /// 字符串列表。
    public func list(_ path: [String]) -> [String] { value(path) as? [String] ?? [] }
    /// 字符串字典。
    public func dictionary(_ path: [String]) -> [String: String] { value(path) as? [String: String] ?? [:] }
    /// 跨层生效值(用于只读展示)。
    public func effective(_ path: [String]) -> (value: Any, scope: ConfigScope)? {
        _ = revision
        return store.effectiveValue(path)
    }

    /// 外部直接修改了文件后调用,立即刷新依赖本模型的视图。
    public func refresh() { revision += 1 }

    // MARK: - 写入

    /// 写入当前层;失败时记录错误。
    /// - Parameters:
    ///   - path: 键路径
    ///   - value: 值,nil 表示删除
    public func set(_ path: [String], _ value: Any?) {
        do {
            try store.set(path, to: value, in: scope)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        revision += 1
    }
}
