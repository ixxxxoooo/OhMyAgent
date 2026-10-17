// @author ixxxxoooo
// 工作区文件监听(无视图):用 FSEvents 监听项目根目录,把「新增/删除/重命名」折算成需要重新列举的目录集合,
// 资源管理器据此自动刷新(不再需要手动点刷新)。过滤规则参考 VS Code 的 `files.watcherExclude`。

import CoreServices
import Foundation

/// 一次文件系统事件(已从 FSEvents 的原始标志折算)。
public struct WorkspaceFSEvent: Equatable, Sendable {
    public let path: String
    /// 目录项本身增/删/改名(只改内容的 Modified 不影响目录列表)
    public let changesListing: Bool
    /// FSEvents 要求整棵子树重新扫描(事件丢失或合并过多)
    public let mustRescan: Bool

    public init(path: String, changesListing: Bool, mustRescan: Bool = false) {
        self.path = path
        self.changesListing = changesListing
        self.mustRescan = mustRescan
    }
}

/// 一批事件折算后的结果。
public struct WorkspaceChangeBatch: Equatable, Sendable {
    /// 目录列表发生变化、需要重新列举的目录(绝对路径,已映射回项目根的写法)
    public var directories: Set<String> = []
    /// 无法精确到目录(事件过多/需要整树重扫):调用方应刷新所有已展开的目录
    public var needsFullRefresh = false

    public var isEmpty: Bool { directories.isEmpty && !needsFullRefresh }
}

/// 事件过滤与折算规则(纯函数,便于测试)。
public enum WorkspaceWatchFilter {
    /// 单批最多精确记录的目录数,超过则退化为整树刷新。
    public static let maxDirectories = 1000

    /// 是否属于不需要监听的噪声路径(对齐 VS Code 的默认排除)。
    /// - Parameters:
    ///   - path: 事件路径
    ///   - root: 项目根目录(与 `path` 同一种写法)
    public static func isNoise(_ path: String, root: String) -> Bool {
        guard path.hasPrefix(root + "/") else { return false }
        let components = path.dropFirst(root.count + 1).split(separator: "/").map(String.init)
        for (index, name) in components.enumerated() {
            // .git 内部变化由 Git 状态轮询负责,资源管理器不展示
            if name == ".git" { return true }
            // node_modules 只关心第一层(包的增删),包内部的海量变化直接忽略
            if name == "node_modules", index + 2 < components.count { return true }
            if [".build", "DerivedData", "__pycache__", ".swiftpm", ".hg"].contains(name) { return true }
        }
        return false
    }

    /// 把事件折算为需要刷新的目录集合。
    /// - Parameters:
    ///   - events: 原始事件(路径已映射到项目根的写法)
    ///   - root: 项目根目录
    /// - Returns: 折算结果
    public static func fold(_ events: [WorkspaceFSEvent], root: String) -> WorkspaceChangeBatch {
        var batch = WorkspaceChangeBatch()
        for event in events {
            if event.mustRescan { batch.needsFullRefresh = true; continue }
            guard event.changesListing, !isNoise(event.path, root: root) else { continue }
            batch.directories.insert((event.path as NSString).deletingLastPathComponent)
            if batch.directories.count > maxDirectories {
                batch.directories = []
                batch.needsFullRefresh = true
                return batch
            }
        }
        return batch
    }
}

/// 工作区监听器:一个根目录一个 FSEvents 流,事件在内部队列上去抖合并后回调。
public final class WorkspaceWatcher: @unchecked Sendable {
    private final class Box {
        let handler: @Sendable ([WorkspaceFSEvent]) -> Void
        init(_ handler: @escaping @Sendable ([WorkspaceFSEvent]) -> Void) { self.handler = handler }
    }

    public let root: String
    private let realRoot: String
    private let onChange: @Sendable (WorkspaceChangeBatch) -> Void
    private let queue = DispatchQueue(label: "oma.workspace-watcher")
    private let debounce: TimeInterval
    private var stream: FSEventStreamRef?
    private var box: Box?
    private var pending: [WorkspaceFSEvent] = []
    private var flushWork: DispatchWorkItem?

    /// - Parameters:
    ///   - root: 项目根目录(绝对路径)
    ///   - debounce: 合并窗口秒数
    ///   - onChange: 折算后的变化回调(在内部队列上调用,调用方自行切回主线程)
    public init(root: String, debounce: TimeInterval = 0.12, onChange: @escaping @Sendable (WorkspaceChangeBatch) -> Void) {
        self.root = root
        self.realRoot = Self.realPath(root)
        self.debounce = debounce
        self.onChange = onChange
    }

    deinit { stop() }

    /// 开始监听(幂等)。目录不存在时静默跳过。
    public func start() {
        queue.sync {
            guard stream == nil, FileManager.default.fileExists(atPath: realRoot) else { return }
            let box = Box { [weak self] events in self?.receive(events) }
            self.box = box
            var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(box).toOpaque(), retain: nil, release: nil, copyDescription: nil)
            let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
                guard let info else { return }
                let box = Unmanaged<Box>.fromOpaque(info).takeUnretainedValue()
                let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
                var events: [WorkspaceFSEvent] = []
                for index in 0..<min(count, paths.count) {
                    events.append(WorkspaceWatcher.event(path: paths[index], flags: UInt32(eventFlags[index])))
                }
                box.handler(events)
            }
            let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
            guard let created = FSEventStreamCreate(nil, callback, &context, [realRoot] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.05, flags) else { return }
            stream = created
            FSEventStreamSetDispatchQueue(created, queue)
            FSEventStreamStart(created)
        }
    }

    /// 停止监听(幂等)。
    public func stop() {
        queue.sync {
            if let stream {
                FSEventStreamStop(stream)
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
                self.stream = nil
            }
            flushWork?.cancel()
            flushWork = nil
            pending = []
            box = nil
        }
    }

    /// 收到一批原始事件:映射路径后入队,去抖后统一折算。
    private func receive(_ events: [WorkspaceFSEvent]) {
        let mapped = events.map { event in
            WorkspaceFSEvent(path: mapToRoot(event.path), changesListing: event.changesListing, mustRescan: event.mustRescan)
        }
        pending.append(contentsOf: mapped)
        flushWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let batch = WorkspaceWatchFilter.fold(self.pending, root: self.root)
            self.pending = []
            if !batch.isEmpty { self.onChange(batch) }
        }
        flushWork = work
        queue.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    /// FSEvents 上报真实路径(/var → /private/var),映射回项目根的写法,让界面路径一致。
    private func mapToRoot(_ path: String) -> String {
        if path == realRoot { return root }
        if path.hasPrefix(realRoot + "/") { return root + String(path.dropFirst(realRoot.count)) }
        return path
    }

    /// 把 FSEvents 标志折算为事件。
    static func event(path: String, flags: UInt32) -> WorkspaceFSEvent {
        let listing = UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemRenamed)
        let rescan = UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped)
        return WorkspaceFSEvent(path: path, changesListing: flags & listing != 0, mustRescan: flags & rescan != 0)
    }

    /// 真实路径(解析所有符号链接)。
    static func realPath(_ path: String) -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(path, &buffer) != nil else { return path }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
