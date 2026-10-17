// @author ixxxxoooo
// 资源管理器、文件索引、全局搜索与命令面板共享的状态模型。

import Foundation
import Observation
import OMLog
import WorkbenchKit

/// 工作区文件索引缓存(按项目根目录),供快速打开与搜索复用。
@MainActor
@Observable
final class WorkspaceIndexModel {
    static let shared = WorkspaceIndexModel()
    private(set) var files: [String] = []
    private(set) var root: String?
    private(set) var isLoading = false
    @ObservationIgnored private var task: Task<Void, Never>?

    /// 刷新索引(后台线程扫描)。
    /// - Parameter root: 项目根目录;nil 清空
    func refresh(root newRoot: String?) {
        task?.cancel()
        root = newRoot
        guard let newRoot else { files = []; return }
        isLoading = true
        task = Task { [weak self] in
            let started = ContinuousClock.now
            let list = await Task.detached(priority: .userInitiated) { WorkspaceFiles.index(root: newRoot) }.value
            guard !Task.isCancelled, let self, self.root == newRoot else { return }
            self.files = list
            self.isLoading = false
            Log.editor.info("文件索引完成", ["root": newRoot, "files": "\(list.count)", "ms": "\(Int((ContinuousClock.now - started).seconds * 1000))"])
        }
    }
}

/// 资源管理器的刷新信号:文件操作后递增,已展开的目录据此重新列举。
@MainActor
@Observable
final class ExplorerModel {
    static let shared = ExplorerModel()
    private(set) var revision = 0
    /// 「折叠全部文件夹」信号:递增后所有已展开的文件夹行收起。
    private(set) var collapseRevision = 0
    /// 各目录的刷新版本:文件监听发现某目录增删文件时递增,只让该目录重新列举。
    private(set) var directoryVersions: [String: Int] = [:]
    func bump() { revision += 1 }
    /// 某目录当前的刷新版本(视图用作 `.task(id:)` 的一部分)。
    func version(of directory: String) -> Int { directoryVersions[directory] ?? 0 }
    /// 标记一批目录需要重新列举(文件监听调用)。
    /// - Parameter directories: 目录绝对路径
    func markDirty(_ directories: Set<String>) {
        for directory in directories { directoryVersions[directory, default: 0] += 1 }
    }
    /// 一键折叠资源管理器中所有已展开的文件夹。
    func collapseAll() { collapseRevision += 1 }
}

/// 全局搜索状态。
@MainActor
@Observable
final class SearchModel {
    static let shared = SearchModel()
    var query = "" { didSet { if query != oldValue { schedule() } } }
    var caseSensitive = false { didSet { if caseSensitive != oldValue { schedule() } } }
    var wholeWord = false { didSet { if wholeWord != oldValue { schedule() } } }
    var isRegex = false { didSet { if isRegex != oldValue { schedule() } } }
    var pathFilter = "" { didSet { if pathFilter != oldValue { schedule() } } }
    private(set) var output: SearchOutput?
    private(set) var isSearching = false
    /// 递增以请求搜索框获得焦点
    private(set) var focusToken = 0
    /// 当前搜索的根目录(由界面在每次调度前更新)
    var root: String?
    @ObservationIgnored private var task: Task<Void, Never>?

    func requestFocus() { focusToken += 1 }

    /// 防抖执行搜索。
    func schedule() {
        task?.cancel()
        guard let root, !query.isEmpty else { output = nil; isSearching = false; return }
        isSearching = true
        let options = SearchOptions(query: query, caseSensitive: caseSensitive, wholeWord: wholeWord, isRegex: isRegex, pathFilter: pathFilter)
        let index = WorkspaceIndexModel.shared
        task = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let started = ContinuousClock.now
            let files = index.root == root && !index.files.isEmpty ? index.files : nil
            let result = await WorkspaceSearch.search(root: root, options: options, files: files)
            guard !Task.isCancelled, let self else { return }
            self.output = result
            self.isSearching = false
            Log.editor.info("全局搜索完成", ["hits": "\(result.totalHits)", "files": "\(result.files.count)", "ms": "\(Int((ContinuousClock.now - started).seconds * 1000))", "error": result.error ?? "-"])
        }
    }
}

/// 工作区文件监听中心:监听当前项目的根目录,把新增/删除/重命名即时反映到资源管理器与文件索引
/// (对标 VS Code 的文件监听,不再需要手动点「刷新」)。
@MainActor
final class WorkspaceWatchCenter {
    static let shared = WorkspaceWatchCenter()
    private var watcher: WorkspaceWatcher?
    private var indexTask: Task<Void, Never>?
    private(set) var root: String?

    /// 切换监听的项目(nil 停止监听);同一根目录重复调用无副作用。
    /// - Parameter newRoot: 项目根目录
    func watch(root newRoot: String?) {
        guard newRoot != root else { return }
        watcher?.stop()
        watcher = nil
        indexTask?.cancel()
        root = newRoot
        guard let newRoot else { return }
        let watcher = WorkspaceWatcher(root: newRoot) { batch in
            Task { @MainActor in WorkspaceWatchCenter.shared.apply(batch, root: newRoot) }
        }
        watcher.start()
        self.watcher = watcher
        Log.editor.info("开始监听工作区文件变化", ["root": newRoot])
    }

    /// 应用一批变化:刷新受影响目录;文件集合变化时节流重建索引(快速打开/搜索用)。
    private func apply(_ batch: WorkspaceChangeBatch, root watched: String) {
        guard watched == root else { return }
        if batch.needsFullRefresh {
            ExplorerModel.shared.bump()
        } else {
            ExplorerModel.shared.markDirty(batch.directories)
        }
        Log.editor.debug("工作区文件变化", ["dirs": "\(batch.directories.count)", "full": "\(batch.needsFullRefresh)"])
        scheduleIndexRefresh(root: watched)
    }

    /// 节流重建文件索引:1.5 秒内的多次变化合并为一次。
    private func scheduleIndexRefresh(root watched: String) {
        indexTask?.cancel()
        indexTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled, let self, self.root == watched else { return }
            WorkspaceIndexModel.shared.refresh(root: watched)
        }
    }
}
