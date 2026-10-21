// @author ixxxxoooo
// IDE 窗口的全局搜索/替换模型:每窗口一份;防抖搜索、结果折叠、替换单条/整文件/全部,并保存最近一次替换以便撤销。

import Foundation
import Observation
import OMLog
import WorkbenchKit

/// 一次替换批次(撤销用):文件路径 → 替换前后的全文。
struct IDEReplaceBatch {
    var title: String
    var files: [(path: String, before: String, after: String)]
}

@MainActor
@Observable
final class IDESearchModel {
    var query = "" { didSet { if query != oldValue { schedule() } } }
    var replacement = ""
    var caseSensitive = false { didSet { if caseSensitive != oldValue { schedule() } } }
    var wholeWord = false { didSet { if wholeWord != oldValue { schedule() } } }
    var isRegex = false { didSet { if isRegex != oldValue { schedule() } } }
    var pathFilter = "" { didSet { if pathFilter != oldValue { schedule() } } }
    var showsReplace = false
    private(set) var output: SearchOutput?
    private(set) var isSearching = false
    /// 已折叠的文件(`SearchFileResult.id`)
    var collapsed: Set<String> = []
    /// 最近一次替换(可撤销)
    private(set) var lastReplace: IDEReplaceBatch?
    /// 聚焦输入框的请求计数
    private(set) var focusToken = 0
    /// 最近一次替换的结果提示(界面显示一行)
    private(set) var notice: String?
    var root: String? { didSet { if root != oldValue { output = nil; schedule() } } }
    @ObservationIgnored private var task: Task<Void, Never>?

    /// 请求聚焦搜索框(⇧⌘F)。
    func requestFocus() { focusToken += 1 }

    /// 当前搜索选项。
    var options: SearchOptions {
        SearchOptions(query: query, caseSensitive: caseSensitive, wholeWord: wholeWord, isRegex: isRegex, pathFilter: pathFilter)
    }

    /// 防抖执行搜索。
    func schedule() {
        task?.cancel()
        guard let root, !query.isEmpty else { output = nil; isSearching = false; return }
        isSearching = true
        let options = options
        task = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let started = ContinuousClock.now
            let index = WorkspaceIndexModel.shared
            let indexed = index.root == root && !index.files.isEmpty
            let result = await WorkspaceSearch.searchRoots([(root, indexed ? index.files : nil)], options: options)
            guard !Task.isCancelled, let self else { return }
            output = result
            isSearching = false
            Log.editor.info("IDE 全局搜索完成", ["hits": "\(result.totalHits)", "files": "\(result.files.count)", "ms": "\(Int((ContinuousClock.now - started).seconds * 1000))"])
        }
    }

    // MARK: 替换

    /// 替换所有结果文件里的全部匹配;有未保存修改的文件跳过。
    func replaceAll() {
        guard let output, let root else { return }
        apply(files: output.files.map { (root + "/" + $0.path, nil) }, title: String(localized: "全部替换"))
    }

    /// 替换某个文件里的全部匹配。
    /// - Parameter file: 搜索结果中的文件
    func replace(file: SearchFileResult) {
        guard let root else { return }
        apply(files: [(root + "/" + file.path, nil)], title: String(localized: "替换文件"))
    }

    /// 只替换某一条命中。
    /// - Parameter hit: 命中
    func replace(hit: SearchHit) {
        guard let root else { return }
        apply(files: [(root + "/" + hit.path, hit.line)], title: String(localized: "替换"))
    }

    /// 执行替换:后台读写文件,完成后刷新搜索与已打开的文档。
    private func apply(files: [(path: String, line: Int?)], title: String) {
        let options = options
        let replacement = replacement
        let dirty = Set(FileDocumentStore.shared.dirtyDocuments.map(\.path))
        Task {
            let outcome = await Task.detached { () -> (batch: [(String, String, String)], count: Int, skipped: [String]) in
                var batch: [(String, String, String)] = []
                var count = 0
                var skipped: [String] = []
                for (path, line) in files {
                    if dirty.contains(path) { skipped.append((path as NSString).lastPathComponent); continue }
                    guard let before = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
                    let result = line.map { SearchReplace.replace(inLine: $0, of: before, options: options, replacement: replacement) }
                        ?? SearchReplace.replaceAll(in: before, options: options, replacement: replacement)
                    guard result.count > 0, (try? result.text.write(toFile: path, atomically: true, encoding: .utf8)) != nil else { continue }
                    batch.append((path, before, result.text))
                    count += result.count
                }
                return (batch, count, skipped)
            }.value
            if !outcome.batch.isEmpty {
                lastReplace = IDEReplaceBatch(title: title, files: outcome.batch.map { (path: $0.0, before: $0.1, after: $0.2) })
            }
            for entry in outcome.batch { await FileDocumentStore.shared.reload(entry.0) }
            var message = String(localized: "已替换 \(outcome.count) 处,\(outcome.batch.count) 个文件")
            if !outcome.skipped.isEmpty {
                let names = outcome.skipped.joined(separator: "、")
                message += String(localized: "(跳过有未保存修改的:\(names))")
            }
            notice = message
            Log.editor.info("IDE 替换", ["title": title, "replaced": "\(outcome.count)", "files": "\(outcome.batch.count)", "skipped": "\(outcome.skipped.count)"])
            schedule()
        }
    }

    /// 撤销最近一次替换:仅当文件内容仍是替换后的内容时才写回,避免覆盖之后的修改。
    func undoReplace() {
        guard let batch = lastReplace else { return }
        lastReplace = nil
        Task {
            let skipped = await Task.detached { () -> [String] in
                var skipped: [String] = []
                for entry in batch.files {
                    guard let current = try? String(contentsOfFile: entry.path, encoding: .utf8), current == entry.after,
                          (try? entry.before.write(toFile: entry.path, atomically: true, encoding: .utf8)) != nil else {
                        skipped.append((entry.path as NSString).lastPathComponent)
                        continue
                    }
                }
                return skipped
            }.value
            for entry in batch.files { await FileDocumentStore.shared.reload(entry.path) }
            notice = skipped.isEmpty ? String(localized: "已撤销替换") : String(localized: "已撤销,但这些文件之后又被修改,已保留:\(skipped.joined(separator: "、"))")
            schedule()
        }
    }

    /// 清除提示。
    func clearNotice() { notice = nil }
}
