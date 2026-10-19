// @author ixxxxoooo
// 资源管理器的文件树状态:展开集合、目录子项缓存与展平后的行数组。
// 展开/折叠/刷新只改这份状态,视图只挂载可见窗口内的行(见 `ExplorerFlatten`),
// 因此展开数千行的目录不会卡住主线程。

import Foundation
import Observation
import OMLog
import WorkbenchKit

@MainActor
@Observable
final class ExplorerTree {
    /// 展平后的全部行(从上到下)
    private(set) var rows: [ExplorerRowItem] = []
    /// 已展开的目录路径(带标题行的附加文件夹根也在其中)
    private(set) var expanded: Set<String> = []

    @ObservationIgnored private var sources: [ExplorerSource] = []
    @ObservationIgnored private var children: [String: [FileEntry]] = [:]
    /// 各目录上次列举时的版本戳,用于判断是否过期
    @ObservationIgnored private var loadedStamp: [String: String] = [:]
    @ObservationIgnored private var loading = false
    @ObservationIgnored private var needsReload = false
    private let model = ExplorerModel.shared

    /// 设置根目录来源(项目根 + 附加文件夹);新出现的附加文件夹默认展开。
    /// - Parameter newSources: 根目录来源
    func configure(_ newSources: [ExplorerSource]) {
        guard newSources != sources else { return }
        let added = newSources.filter { $0.showsHeader && !sources.contains($0) }
        sources = newSources
        for source in added { expanded.insert(source.root) }
        rebuild()
        refresh()
    }

    /// 切换某目录(或附加文件夹根)的展开状态。
    /// - Parameter path: 目录绝对路径
    func toggle(_ path: String) {
        guard !path.isEmpty else { return }
        if expanded.contains(path) { collapse(path) } else { expand(path) }
    }

    /// 展开某目录并按需列举。
    /// - Parameter path: 目录绝对路径
    func expand(_ path: String) {
        guard !path.isEmpty, !expanded.contains(path) else { return }
        expanded.insert(path)
        rebuild()
        refresh()
    }

    /// 折叠某目录,同时丢弃其下所有已展开的后代(与逐层视图卸载时的行为一致)。
    /// - Parameter path: 目录绝对路径
    func collapse(_ path: String) {
        guard expanded.contains(path) else { return }
        let prefix = path + "/"
        expanded = expanded.filter { $0 != path && !$0.hasPrefix(prefix) }
        rebuild()
    }

    /// 折叠全部文件夹(附加文件夹的根节点保持展开)。
    func collapseAll() {
        let headers = Set(sources.filter(\.showsHeader).map(\.root))
        expanded = expanded.intersection(headers)
        rebuild()
    }

    /// 变化标识:文件监听、手动刷新、展开集合变化时改变,视图用它触发 `refresh()`。
    var refreshToken: String {
        var versions = 0
        for path in expanded.union(sources.map(\.root)) { versions &+= model.version(of: path) }
        return "\(model.revision)#\(versions)#\(expanded.count)#\(sources.count)"
    }

    /// 重新列举过期或尚未加载的目录(根与已展开的目录),完成后重建行。
    func refresh() {
        guard !loading else { needsReload = true; return }
        let wanted = Set(sources.map(\.root)).union(expanded)
        let stamps = Dictionary(uniqueKeysWithValues: wanted.map { ($0, stamp(of: $0)) })
        let stale = wanted.filter { loadedStamp[$0] != stamps[$0] }
        guard !stale.isEmpty else { return }
        loading = true
        Task {
            let started = ContinuousClock.now
            let listed = await Task.detached(priority: .userInitiated) { () -> [String: [FileEntry]] in
                var result: [String: [FileEntry]] = [:]
                for path in stale { result[path] = WorkspaceFiles.list(directory: path) }
                return result
            }.value
            for (path, entries) in listed {
                children[path] = entries
                loadedStamp[path] = stamps[path]
            }
            rebuild()
            loading = false
            Log.editor.debug("资源管理器列举目录", ["dirs": "\(stale.count)", "rows": "\(rows.count)", "elapsed": "\(started.duration(to: .now))"])
            if needsReload { needsReload = false; refresh() }
        }
    }

    /// 重新展平。
    private func rebuild() {
        rows = ExplorerFlatten.rows(sources: sources, children: children, expanded: expanded)
    }

    private func stamp(of path: String) -> String { "\(model.revision)#\(model.version(of: path))" }
}
