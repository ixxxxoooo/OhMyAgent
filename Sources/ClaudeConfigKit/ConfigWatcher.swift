// @author ixxxxoooo
// 配置变更监听:FSEvents 监听 ~/.claude 与工作区(带路径过滤与去抖),~/.claude.json 用轻量轮询。

import CoreServices
import Foundation
import Synchronization

/// 配置监听器。变化后在内部队列上回调(已去抖)。
public final class ConfigWatcher: @unchecked Sendable {
    private final class Box {
        let handler: @Sendable ([String]) -> Void
        init(_ handler: @escaping @Sendable ([String]) -> Void) { self.handler = handler }
    }

    private let paths: ClaudePaths
    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "oma.config-watcher")
    private let debounce: TimeInterval
    private var stream: FSEventStreamRef?
    private var box: Box?
    private var pending: DispatchWorkItem?
    private var pollTimer: DispatchSourceTimer?
    private var lastClaudeJSON: Date?

    /// - Parameters:
    ///   - paths: 需要监听的路径集合
    ///   - debounce: 去抖秒数
    ///   - onChange: 变更回调(任意线程)
    public init(paths: ClaudePaths, debounce: TimeInterval = 0.3, onChange: @escaping @Sendable () -> Void) {
        self.paths = paths
        self.debounce = debounce
        self.onChange = onChange
    }

    deinit { stop() }

    /// 开始监听。
    public func start() {
        queue.sync {
            guard stream == nil else { return }
            // FSEvents 上报真实路径,需先解析符号链接(如 /var → /private/var)
            let claudeDirectory = Self.realPath(paths.claudeDirectory)
            let workspacePath = paths.workspace.map { Self.realPath($0) }
            var roots = [claudeDirectory]
            if let workspacePath { roots.append(workspacePath) }
            let box = Box { [weak self] changed in
                guard changed.contains(where: { Self.isRelevant($0, claudeDirectory: claudeDirectory, workspace: workspacePath) }) else { return }
                self?.schedule()
            }
            self.box = box
            var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(box).toOpaque(), retain: nil, release: nil, copyDescription: nil)
            let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
                guard let info else { return }
                let box = Unmanaged<Box>.fromOpaque(info).takeUnretainedValue()
                let array = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
                box.handler(Array(array.prefix(count)))
            }
            let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
            guard let created = FSEventStreamCreate(nil, callback, &context, roots as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.15, flags) else { return }
            stream = created
            FSEventStreamSetDispatchQueue(created, queue)
            FSEventStreamStart(created)

            lastClaudeJSON = Self.modificationDate(paths.claudeJSON)
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 2, repeating: 2)
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                let current = Self.modificationDate(self.paths.claudeJSON)
                if current != self.lastClaudeJSON {
                    self.lastClaudeJSON = current
                    self.schedule()
                }
            }
            timer.resume()
            pollTimer = timer
        }
    }

    /// 停止监听。
    public func stop() {
        queue.sync {
            if let stream {
                FSEventStreamStop(stream)
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
                self.stream = nil
            }
            pollTimer?.cancel()
            pollTimer = nil
            pending?.cancel()
            pending = nil
            box = nil
        }
    }

    private func schedule() {
        pending?.cancel()
        let work = DispatchWorkItem { [onChange] in onChange() }
        pending = work
        queue.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    /// 判断路径是否与 Claude 配置相关(过滤工作区里的无关文件事件)。
    static func isRelevant(_ path: String, claudeDirectory: String, workspace: String?) -> Bool {
        if path.hasPrefix(claudeDirectory + "/") {
            let relative = String(path.dropFirst(claudeDirectory.count + 1))
            if relative.hasPrefix("settings") || relative == "CLAUDE.md" { return true }
            if relative.hasPrefix("plugins/"), !relative.hasPrefix("plugins/cache/"), !relative.hasPrefix("plugins/marketplaces/") { return true }
            return ["skills/", "agents/", "commands/", "rules/"].contains { relative.hasPrefix($0) }
        }
        guard let workspace, path.hasPrefix(workspace + "/") else { return false }
        let relative = String(path.dropFirst(workspace.count + 1))
        if relative.hasPrefix(".claude/") || relative == ".claude" { return true }
        return ["CLAUDE.md", "CLAUDE.local.md", "AGENTS.md", ".mcp.json"].contains(relative)
    }

    /// 真实路径(解析所有符号链接;`URL.resolvingSymlinksInPath` 会去掉 /private 前缀,与 FSEvents 上报不一致)。
    static func realPath(_ url: URL) -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(url.path, &buffer) != nil else { return url.path }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}
