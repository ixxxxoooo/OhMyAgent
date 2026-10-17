// @author ixxxxoooo
// 工作区文本搜索索引(对照 Cursor 的 Instant Grep):三元组(trigram)倒排索引,仅在本机内存里构建,不上传。
// 思路:把每个文件小写化后的 UTF-8 三字节组合登记到倒排表;查询时先用查询里的字面量求交集,得到少量候选文件,
// 再交给现有的逐文件正则扫描确认(索引只负责缩小范围,命中判定仍由 `WorkspaceSearch.searchFile` 完成,因此不会漏也不会错)。
// 增量更新:每次查询前按 mtime+大小比对,只重建变化的文件;索引未就绪、查询没有可用字面量时回退全量扫描。

import Foundation
import OMLog

/// 文本搜索索引(单个工作区根目录)。
public actor SearchIndex {
    /// 文件登记状态。
    enum Kind: Sendable {
        /// 已建索引
        case indexed
        /// 过大,不建索引,查询时一律作为候选
        case large
        /// 二进制或无法按 UTF-8 解码,不参与搜索
        case skipped
    }

    struct Entry: Sendable {
        var id: Int32
        var mtime: Double
        var size: Int
        var trigrams: [UInt32]
        var kind: Kind
    }

    /// 单文件建索引的上限(更大的文件当作「总是候选」)。
    static let maxIndexedBytes = 1_000_000
    /// 索引文件数上限,超出的文件当作「总是候选」。
    static let maxIndexedFiles = 60_000

    public let root: String
    private var entries: [String: Entry] = [:]
    private var paths: [Int32: String] = [:]
    private var postings: [UInt32: [Int32]] = [:]
    private var nextID: Int32 = 0
    private var building: Task<Void, Never>?
    private var lastSync = Date.distantPast
    private let log = Log.editor

    /// 首次构建完成后为 true。
    public private(set) var isReady = false
    /// 已建索引的文件数(测试与状态展示)。
    public var indexedFileCount: Int { entries.values.filter { $0.kind == .indexed }.count }

    public init(root: String) {
        self.root = root
    }

    // MARK: - 同步

    /// 让索引跟上磁盘:首次调用在后台构建(立即返回),之后每次增量比对 mtime(同一秒内的重复调用跳过)。
    /// - Parameters:
    ///   - files: 工作区当前文件(相对路径)
    ///   - force: 忽略节流立即同步(测试用)
    public func sync(files: [String], force: Bool = false) async {
        if !isReady {
            if building == nil {
                building = Task { [weak self] in
                    await self?.performSync(files: files)
                    await self?.finishBuild()
                }
            }
            return
        }
        if !force, Date().timeIntervalSince(lastSync) < 1 { return }
        await performSync(files: files)
    }

    /// 等待首次构建结束(测试与预热用)。
    public func waitUntilReady() async {
        await building?.value
    }

    private func finishBuild() {
        isReady = true
        building = nil
    }

    private func performSync(files: [String]) async {
        let started = ContinuousClock.now
        lastSync = Date()
        let known = entries.mapValues { StampOnly(mtime: $0.mtime, size: $0.size) }
        let root = root
        let plan = await Task.detached(priority: .utility) { Self.plan(root: root, files: files, known: known) }.value
        // 并发提取三元组
        let extracted = await Self.extract(root: root, paths: plan.changed)
        let before = entries.count
        for rel in plan.removed { remove(rel) }
        var indexedFiles = entries.values.filter { $0.kind == .indexed }.count
        for item in extracted {
            remove(item.path)
            var kind = item.kind
            if kind == .indexed, indexedFiles >= Self.maxIndexedFiles { kind = .large }
            if kind == .indexed { indexedFiles += 1 }
            add(path: item.path, stamp: item.stamp, trigrams: kind == .indexed ? item.trigrams : [], kind: kind)
        }
        if !plan.changed.isEmpty || !plan.removed.isEmpty {
            log.info("搜索索引已同步", ["root": (root as NSString).lastPathComponent, "changed": "\(plan.changed.count)", "removed": "\(plan.removed.count)",
                                        "files": "\(before)→\(entries.count)", "ms": "\(OMLogger.milliseconds(since: started))"])
        }
    }

    private func add(path: String, stamp: StampOnly, trigrams: [UInt32], kind: Kind) {
        let id = nextID
        nextID += 1
        entries[path] = Entry(id: id, mtime: stamp.mtime, size: stamp.size, trigrams: trigrams, kind: kind)
        paths[id] = path
        // 新 id 恒大于已有 id,追加即保持有序
        for gram in trigrams { postings[gram, default: []].append(id) }
    }

    private func remove(_ path: String) {
        guard let entry = entries.removeValue(forKey: path) else { return }
        paths[entry.id] = nil
        for gram in entry.trigrams {
            guard var list = postings[gram], let index = Self.lowerBound(list, entry.id), index < list.count, list[index] == entry.id else { continue }
            list.remove(at: index)
            postings[gram] = list.isEmpty ? nil : list
        }
    }

    // MARK: - 查询

    /// 用索引缩小候选文件范围。
    /// - Parameters:
    ///   - options: 搜索选项
    ///   - files: 工作区当前文件(相对路径)
    /// - Returns: 候选相对路径;索引未就绪或查询没有可用字面量(过短、正则含分支)时返回 nil,调用方应全量扫描
    public func candidates(for options: SearchOptions, files: [String]) -> [String]? {
        guard isReady, let grams = Self.queryTrigrams(options), !grams.isEmpty else { return nil }
        var lists: [[Int32]] = []
        for gram in grams {
            guard let list = postings[gram] else { return fallbackOnly(files: files) }
            lists.append(list)
        }
        lists.sort { $0.count < $1.count }
        var ids = lists[0]
        for list in lists.dropFirst() where !ids.isEmpty { ids = Self.intersect(ids, list) }
        let current = Set(files)
        var result = ids.compactMap { paths[$0] }.filter { current.contains($0) }
        result += fallbackOnly(files: files)
        return result
    }

    /// 总是需要扫描的文件:尚未登记的新文件与过大的文件。
    private func fallbackOnly(files: [String]) -> [String] {
        files.filter { rel in
            guard let entry = entries[rel] else { return true }
            return entry.kind == .large
        }
    }

    // MARK: - 纯函数(可测试)

    struct StampOnly: Sendable, Equatable {
        var mtime: Double
        var size: Int
    }

    struct Plan: Sendable {
        var changed: [String: StampOnly]
        var removed: [String]
    }

    struct Extracted: Sendable {
        var path: String
        var stamp: StampOnly
        var trigrams: [UInt32]
        var kind: Kind
    }

    /// 比对磁盘:找出新增/变化与已删除的文件。
    static func plan(root: String, files: [String], known: [String: StampOnly]) -> Plan {
        var changed: [String: StampOnly] = [:]
        let base = root.hasSuffix("/") ? root : root + "/"
        var present = Set<String>()
        present.reserveCapacity(files.count)
        for rel in files {
            present.insert(rel)
            var info = stat()
            guard stat(base + rel, &info) == 0 else { continue }
            let mtime = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9
            let stamp = StampOnly(mtime: mtime, size: Int(info.st_size))
            if known[rel] != stamp { changed[rel] = stamp }
        }
        let removed = known.keys.filter { !present.contains($0) }
        return Plan(changed: changed, removed: removed)
    }

    /// 并发读取文件并提取三元组。
    static func extract(root: String, paths: [String: StampOnly]) async -> [Extracted] {
        let base = root.hasSuffix("/") ? root : root + "/"
        let items = Array(paths)
        return await withTaskGroup(of: Extracted.self) { group in
            var iterator = items.makeIterator()
            var running = 0
            var output: [Extracted] = []
            output.reserveCapacity(items.count)
            func next(_ group: inout TaskGroup<Extracted>) -> Bool {
                guard let (rel, stamp) = iterator.next() else { return false }
                group.addTask { extractOne(path: base + rel, relative: rel, stamp: stamp) }
                return true
            }
            while running < 8, next(&group) { running += 1 }
            while let item = await group.next() {
                running -= 1
                output.append(item)
                if next(&group) { running += 1 }
            }
            return output
        }
    }

    static func extractOne(path: String, relative: String, stamp: StampOnly) -> Extracted {
        if stamp.size > WorkspaceSearch.maxFileBytes { return Extracted(path: relative, stamp: stamp, trigrams: [], kind: .skipped) }
        if stamp.size > maxIndexedBytes { return Extracted(path: relative, stamp: stamp, trigrams: [], kind: .large) }
        guard let data = FileManager.default.contents(atPath: path), !data.prefix(8_192).contains(0),
              let text = String(data: data, encoding: .utf8) else {
            return Extracted(path: relative, stamp: stamp, trigrams: [], kind: .skipped)
        }
        return Extracted(path: relative, stamp: stamp, trigrams: trigrams(of: text), kind: .indexed)
    }

    /// 文本的三元组集合(小写化后的 UTF-8 三字节),升序去重。
    static func trigrams(of text: String) -> [UInt32] {
        let bytes = Array(text.lowercased().utf8)
        guard bytes.count >= 3 else { return [] }
        var set = Set<UInt32>()
        set.reserveCapacity(min(bytes.count, 4096))
        for i in 0..<(bytes.count - 2) {
            set.insert(UInt32(bytes[i]) << 16 | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i + 2]))
        }
        return set.sorted()
    }

    /// 查询必须出现的三元组;没有可用字面量(过短、含分支的正则)时返回 nil。
    static func queryTrigrams(_ options: SearchOptions) -> [UInt32]? {
        let literals: [String]
        if options.isRegex {
            guard let required = requiredLiterals(of: options.query) else { return nil }
            literals = required
        } else {
            literals = [options.query]
        }
        var grams = Set<UInt32>()
        for literal in literals where !literal.contains("\n") { grams.formUnion(trigrams(of: literal)) }
        return grams.isEmpty ? nil : Array(grams)
    }

    /// 从正则里提取「一定会出现」的字面量片段(保守:拿不准就不提取)。
    /// 含 `|`(分支)时返回 nil;分组内的内容整体忽略(可能被量词修饰);被 `* ? {` 修饰的字符不计入。
    /// - Parameter pattern: 正则
    /// - Returns: 字面量片段(已小写),或 nil 表示不可用
    static func requiredLiterals(of pattern: String) -> [String]? {
        if pattern.contains("|") { return nil }
        var runs: [String] = []
        var run: [Character] = []
        var depth = 0
        let chars = Array(pattern)
        var i = 0
        func flush() {
            if run.count >= 3 { runs.append(String(run).lowercased()) }
            run.removeAll()
        }
        while i < chars.count {
            let c = chars[i]
            switch c {
            case "\\":
                guard i + 1 < chars.count else { flush(); i += 1; continue }
                let next = chars[i + 1]
                if next.isLetter || next.isNumber {
                    // \d \w \s \b \n \1 等:不是字面量
                    flush()
                } else if depth == 0 {
                    run.append(next)
                }
                i += 2
                continue
            case "[":
                flush()
                var j = i + 1
                while j < chars.count, chars[j] != "]" { if chars[j] == "\\" { j += 1 }; j += 1 }
                i = j + 1
                continue
            case "(":
                flush()
                depth += 1
            case ")":
                flush()
                depth = max(0, depth - 1)
            case "*", "?":
                if !run.isEmpty { run.removeLast() }
                flush()
            case "{":
                if !run.isEmpty { run.removeLast() }
                flush()
                var j = i + 1
                while j < chars.count, chars[j] != "}" { j += 1 }
                i = j + 1
                continue
            case "+", ".", "^", "$":
                flush()
            default:
                if depth == 0 { run.append(c) }
            }
            i += 1
        }
        flush()
        return runs
    }

    /// 升序数组里第一个 ≥ value 的下标。
    static func lowerBound(_ list: [Int32], _ value: Int32) -> Int? {
        var low = 0, high = list.count
        while low < high {
            let mid = (low + high) / 2
            if list[mid] < value { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// 两个升序数组求交集。
    static func intersect(_ a: [Int32], _ b: [Int32]) -> [Int32] {
        var result: [Int32] = []
        var i = 0, j = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] { result.append(a[i]); i += 1; j += 1 }
            else if a[i] < b[j] { i += 1 } else { j += 1 }
        }
        return result
    }
}

/// 各工作区根目录的索引登记处(最多保留最近使用的 6 个)。
public actor SearchIndexRegistry {
    public static let shared = SearchIndexRegistry()
    private var indexes: [String: SearchIndex] = [:]
    private var order: [String] = []
    private let capacity = 6

    /// 取(或创建)某个根目录的索引。
    /// - Parameter root: 工作区根目录
    public func index(for root: String) -> SearchIndex {
        if let existing = indexes[root] {
            order.removeAll { $0 == root }
            order.append(root)
            return existing
        }
        let created = SearchIndex(root: root)
        indexes[root] = created
        order.append(root)
        while order.count > capacity {
            let oldest = order.removeFirst()
            indexes[oldest] = nil
        }
        return created
    }

    /// 丢弃某个根目录的索引(项目移除时释放内存)。
    public func drop(root: String) {
        indexes[root] = nil
        order.removeAll { $0 == root }
    }
}
