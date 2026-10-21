// @author ixxxxoooo
// IDE 窗口注册表:进程内唯一,管理所有 IDE 窗口模型、最近使用顺序与「同一根目录复用窗口」规则,
// 状态变化后防抖落盘到 `ide-windows.json`(退出时同步落盘)。

import Foundation
import Observation
import OMLog

@MainActor
@Observable
public final class IDEWindowRegistry {
    /// 所有 IDE 窗口,最近使用的在前。
    public private(set) var windows: [IDEWindowModel] = []

    @ObservationIgnored private let store: IDEWindowStore
    @ObservationIgnored private let writer: IDEWindowWriter
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    /// 落盘防抖间隔
    @ObservationIgnored private let debounce: Duration

    /// 创建注册表并载入已保存的窗口。
    /// - Parameters:
    ///   - store: 状态文件存取
    ///   - debounce: 防抖间隔(测试可缩短)
    public init(store: IDEWindowStore = IDEWindowStore(), debounce: Duration = .milliseconds(400)) {
        self.store = store
        self.debounce = debounce
        writer = IDEWindowWriter(store: store)
        windows = store.load().windows.map { attach(IDEWindowModel(snapshot: $0)) }
    }

    // MARK: 查询

    /// 按标识查找。
    /// - Parameter id: 窗口标识
    public func window(id: UUID) -> IDEWindowModel? { windows.first { $0.id == id } }

    /// 按工作区根目录查找(规范化后比较;空根不匹配任何窗口)。
    /// - Parameter root: 目录路径
    public func window(forRoot root: String?) -> IDEWindowModel? {
        guard let key = IDEMetrics.normalizedRoot(root) else { return nil }
        return windows.first { $0.workspaceRoot == key }
    }

    /// 最近使用的窗口。
    public var mostRecent: IDEWindowModel? { windows.first }

    // MARK: 增删与激活

    /// 取得某根目录对应的窗口:已有则复用(除非强制新开),否则新建。
    /// - Parameters:
    ///   - root: 工作区根目录;nil 表示空窗口(总是新建)
    ///   - forceNew: 强制新开(⌥ 点击)
    /// - Returns: 窗口模型与是否新建
    public func open(root: String?, forceNew: Bool = false) -> (model: IDEWindowModel, created: Bool) {
        if !forceNew, let existing = window(forRoot: root) { return (existing, false) }
        let model = attach(IDEWindowModel(snapshot: IDEWindowSnapshot(workspaceRoot: root)))
        windows.insert(model, at: 0)
        scheduleSave()
        Log.app.info("新建 IDE 窗口", ["id": model.id.uuidString, "root": model.workspaceName ?? "-", "total": "\(windows.count)"])
        return (model, true)
    }

    /// 把窗口移到最近使用的首位并更新激活时间。
    /// - Parameter id: 窗口标识
    public func activate(_ id: UUID) {
        guard let index = windows.firstIndex(where: { $0.id == id }) else { return }
        let model = windows[index]
        if index != 0 {
            windows.remove(at: index)
            windows.insert(model, at: 0)
        }
        model.markActivated()
    }

    /// 移除窗口(用户关闭窗口时调用;应用退出不调用,以便下次启动恢复)。
    /// - Parameter id: 窗口标识
    public func remove(_ id: UUID) {
        guard let index = windows.firstIndex(where: { $0.id == id }) else { return }
        windows.remove(at: index)
        scheduleSave()
        Log.app.info("移除 IDE 窗口", ["id": id.uuidString, "left": "\(windows.count)"])
    }

    // MARK: 落盘

    /// 当前所有窗口的状态(最近使用在前)。
    public func state() -> IDEWindowsState {
        IDEWindowsState(windows: windows.map { $0.snapshot() })
    }

    /// 防抖后异步落盘。
    public func scheduleSave() {
        saveTask?.cancel()
        let delay = debounce
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.flushAsync()
        }
    }

    /// 立即把当前状态交给后台写盘。
    public func flushAsync() {
        generation += 1
        let snapshot = state()
        let current = generation
        let writer = writer
        Task.detached(priority: .utility) { await writer.write(snapshot, generation: current) }
    }

    /// 同步落盘(应用退出时用;先取消待执行的防抖)。
    public func saveNow() {
        saveTask?.cancel()
        generation += 1
        do { try store.save(state()) } catch {
            Log.app.error("IDE 窗口状态同步写入失败", error: error, ["file": store.fileURL.lastPathComponent])
        }
    }

    private func attach(_ model: IDEWindowModel) -> IDEWindowModel {
        model.onChange = { [weak self] in self?.scheduleSave() }
        return model
    }
}
