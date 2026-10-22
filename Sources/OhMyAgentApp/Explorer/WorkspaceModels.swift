// @author ixxxxoooo
// 资源管理器、文件索引、全局搜索与命令面板共享的状态模型。

import Foundation
import Observation
import OMLog
import WorkbenchKit

/// 附加文件夹里的一个文件(多文件夹工作区)。
struct ExtraIndexedFile: Hashable, Sendable {
    /// 所属附加文件夹(绝对路径)
    let root: String
    /// 相对该文件夹的路径
    let path: String
}

/// 工作区文件索引缓存(按项目根目录),供快速打开与搜索复用。
/// 多文件夹工作区:主目录的文件放在 `files`(相对主目录),附加文件夹的文件放在 `extraFiles`。
@MainActor
@Observable
final class WorkspaceIndexModel {
    static let shared = WorkspaceIndexModel()
    private(set) var files: [String] = []
    private(set) var extraFiles: [ExtraIndexedFile] = []
    private(set) var root: String?
    private(set) var isLoading = false
    /// 查询某项目的附加文件夹(由应用层接到工作台模型);默认没有。
    @ObservationIgnored var extraRootsProvider: @MainActor (String) -> [String] = { _ in [] }
    @ObservationIgnored private var task: Task<Void, Never>?
    /// 整树刷新的代数:增量更新只在代数没变时落地(期间发生了整树刷新则丢弃,以整树结果为准)
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var incrementalTask: Task<Void, Never>?

    /// 按文件系统事件增量更新主目录的索引(后台线程);不适用时(目录过多、索引尚未建好)改为整树刷新。
    /// - Parameters:
    ///   - directories: 变化的目录(绝对路径)
    ///   - watched: 项目根目录
    func applyChanges(directories: Set<String>, root watched: String) {
        guard root == watched, !isLoading, !files.isEmpty, directories.count <= WorkspaceFiles.maxIncrementalDirectories else {
            refresh(root: watched)
            return
        }
        let snapshot = files
        let expected = generation
        incrementalTask?.cancel()
        incrementalTask = Task { [weak self] in
            let started = ContinuousClock.now
            let updated = await Task.detached(priority: .utility) {
                WorkspaceFiles.applyingChanges(to: snapshot, root: watched, directories: directories)
            }.value
            guard !Task.isCancelled, let self, self.root == watched, self.generation == expected else { return }
            guard let updated else { self.refresh(root: watched); return }
            if updated != self.files { self.files = updated }
            Log.editor.debug("文件索引增量更新", ["dirs": "\(directories.count)", "files": "\(updated.count)",
                                              "ms": "\(Int((ContinuousClock.now - started).seconds * 1000))"])
        }
    }

    /// 刷新索引(后台线程扫描主目录与全部附加文件夹)。
    /// - Parameter root: 项目根目录;nil 清空
    func refresh(root newRoot: String?) {
        task?.cancel()
        incrementalTask?.cancel()
        generation &+= 1
        root = newRoot
        guard let newRoot else { files = []; extraFiles = []; return }
        let extras = extraRootsProvider(newRoot)
        isLoading = true
        task = Task { [weak self] in
            let started = ContinuousClock.now
            let (list, extraList) = await Task.detached(priority: .userInitiated) {
                (WorkspaceFiles.index(root: newRoot),
                 extras.flatMap { folder in WorkspaceFiles.index(root: folder).map { ExtraIndexedFile(root: folder, path: $0) } })
            }.value
            guard !Task.isCancelled, let self, self.root == newRoot else { return }
            self.files = list
            self.extraFiles = extraList
            self.isLoading = false
            Log.editor.info("文件索引完成", ["root": newRoot, "files": "\(list.count)", "extraRoots": "\(extras.count)", "extraFiles": "\(extraList.count)", "ms": "\(Int((ContinuousClock.now - started).seconds * 1000))"])
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
            let indexed = index.root == root && !index.files.isEmpty
            var targets: [(root: String, files: [String]?)] = [(root, indexed ? index.files : nil)]
            for folder in index.extraRootsProvider(root) {
                let list = index.root == root ? index.extraFiles.filter { $0.root == folder }.map(\.path) : []
                targets.append((folder, list.isEmpty ? nil : list))
            }
            let result = await WorkspaceSearch.searchRoots(targets, options: options)
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
    private var watchers: [WorkspaceWatcher] = []
    private var indexTask: Task<Void, Never>?
    /// 节流期间累积的变化:目录集合与是否必须整树重建
    private var pendingIndexDirectories: Set<String> = []
    private var pendingIndexFull = false
    /// 变化订阅者(打开的文件、Diff 视图):文件内容或 Git 状态变化时收到信号,取代按固定间隔轮询磁盘/`git diff`
    private var subscribers: [UUID: AsyncStream<Void>.Continuation] = [:]
    private(set) var root: String?
    private(set) var extraRoots: [String] = []

    /// 切换监听的项目(nil 停止监听);主目录与附加文件夹都没变化时无副作用。
    /// - Parameters:
    ///   - newRoot: 项目根目录
    ///   - extras: 多文件夹工作区的附加文件夹
    func watch(root newRoot: String?, extras: [String] = []) {
        guard newRoot != root || extras != extraRoots else { return }
        watchers.forEach { $0.stop() }
        watchers = []
        // 监听范围变了:结束现有订阅,订阅方(`follow`)据此重新判断自己的路径是否仍被覆盖
        subscribers.values.forEach { $0.finish() }
        subscribers = [:]
        indexTask?.cancel()
        pendingIndexDirectories = []
        pendingIndexFull = false
        root = newRoot
        extraRoots = newRoot == nil ? [] : extras
        guard let newRoot else { return }
        for folder in [newRoot] + extraRoots {
            let watcher = WorkspaceWatcher(root: folder) { batch in
                Task { @MainActor in WorkspaceWatchCenter.shared.apply(batch, root: folder) }
            }
            watcher.start()
            watchers.append(watcher)
        }
        Log.editor.info("开始监听工作区文件变化", ["root": newRoot, "extraRoots": "\(extraRoots.count)"])
    }

    /// 订阅文件内容/Git 状态变化(已在监听器内去抖 0.12 秒);任务取消即自动退订。
    /// - Returns: 变化信号流(只保留最新一次,慢消费者不会积压)
    func changes() -> AsyncStream<Void> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            subscribers[id] = continuation
            continuation.onTermination = { _ in
                Task { @MainActor in WorkspaceWatchCenter.shared.subscribers[id] = nil }
            }
        }
    }

    /// 跟随某个路径的变化直到任务取消:被监听覆盖时由文件系统事件驱动(空闲零开销),否则按 `poll` 间隔低频轮询;
    /// 切换项目导致监听范围变化时自动在两种方式之间切换,不会因为订阅失效而再也收不到变化。
    /// - Parameters:
    ///   - path: 文件路径
    ///   - poll: 未被覆盖时的轮询间隔
    ///   - debounce: 收到事件后再等多久(合并连续写入)
    ///   - onChange: 可能有变化时的回调
    func follow(_ path: String, poll: Duration, debounce: Duration = .zero, _ onChange: () async -> Void) async {
        while !Task.isCancelled {
            if covers(path) {
                for await _ in changes() {
                    if debounce > .zero { try? await Task.sleep(for: debounce) }
                    guard !Task.isCancelled else { return }
                    await onChange()
                }
                // 订阅被结束(监听范围已切换):补查一次再重新判断
                guard !Task.isCancelled else { return }
                await onChange()
            } else {
                try? await Task.sleep(for: poll)
                guard !Task.isCancelled else { return }
                await onChange()
            }
        }
    }

    /// 该路径的变化是否由监听覆盖(在被监听的目录内,且不属于 `.git`/构建产物等噪声);未覆盖的调用方需自行低频轮询。
    func covers(_ path: String) -> Bool {
        ((root.map { [$0] } ?? []) + extraRoots).contains { folder in
            path.hasPrefix(folder + "/") && !WorkspaceWatchFilter.isNoise(path, root: folder)
        }
    }

    /// 应用一批变化:刷新受影响目录;文件集合变化时节流重建索引(快速打开/搜索用)。
    private func apply(_ batch: WorkspaceChangeBatch, root watched: String) {
        guard watched == root || extraRoots.contains(watched), let primary = root else { return }
        if batch.touched || batch.gitChanged { subscribers.values.forEach { $0.yield() } }
        guard !batch.directories.isEmpty || batch.needsFullRefresh else { return }
        if batch.needsFullRefresh {
            ExplorerModel.shared.bump()
        } else {
            ExplorerModel.shared.markDirty(batch.directories)
        }
        Log.editor.debug("工作区文件变化", ["dirs": "\(batch.directories.count)", "full": "\(batch.needsFullRefresh)"])
        // 附加文件夹的变化、无法精确到目录的变化与过多目录:整树重建;否则只增量更新这些目录
        if watched != primary || batch.needsFullRefresh { pendingIndexFull = true } else { pendingIndexDirectories.formUnion(batch.directories) }
        scheduleIndexRefresh(root: primary)
    }

    /// 节流更新文件索引:1.5 秒内的多次变化合并为一次(能精确到目录时增量更新,否则整树重建)。
    private func scheduleIndexRefresh(root watched: String) {
        indexTask?.cancel()
        indexTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled, let self, self.root == watched else { return }
            let directories = self.pendingIndexDirectories
            let full = self.pendingIndexFull || directories.count > WorkspaceFiles.maxIncrementalDirectories
            self.pendingIndexDirectories = []
            self.pendingIndexFull = false
            if full { WorkspaceIndexModel.shared.refresh(root: watched) } else { WorkspaceIndexModel.shared.applyChanges(directories: directories, root: watched) }
        }
    }
}
