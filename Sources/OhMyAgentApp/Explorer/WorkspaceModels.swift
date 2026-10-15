// @author ygw
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
    func bump() { revision += 1 }
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
