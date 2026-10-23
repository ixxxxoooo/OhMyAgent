// @author ixxxxoooo
// 语法片段仓库:在后台 actor(`HighlightEngine`,tree-sitter 增量解析)里解析,只把「视口附近」的片段取回主线程。
// 编辑发生时先在主线程平移现有片段(输入不闪色),随后在后台增量同步语法树并回写,主线程不做任何解析。

import AppKit
import Darwin
import EditorCore
import OMLog

@MainActor
final class NativeTokenStore {
    /// 后台高亮引擎。
    let engine = HighlightEngine()
    /// 片段集合(`id` 为文档顺序,后者覆盖前者),覆盖 `covered` 区间。
    private(set) var tokens = DecorationSet()
    /// 已取回片段的 UTF-16 区间。
    private(set) var covered = NSRange(location: 0, length: 0)
    /// 取回区间向视口两侧额外扩展的字符数。
    static let padding = 12_000

    private var language: SyntaxLanguage = .plain
    private var engineLength = -1
    private var pendingEdits: [AppliedEdit] = []
    private var pendingSnapshot: TextRope?
    private var needsRebuild = true
    private var syncing = false
    private var dirty = false
    private var desired = NSRange(location: 0, length: 0)
    /// 取回完成后回调(视图据此丢弃行布局缓存并重绘)。
    var onUpdate: (() -> Void)?
    /// 同步完成后的次数,测试与基准使用。
    private(set) var syncCount = 0
    private var generation = 0

    /// 装入新文本与语言(切换文件、重新载入)。
    func load(snapshot: TextRope, language: SyntaxLanguage, desired range: NSRange) {
        generation += 1
        self.language = language
        pendingEdits = []
        pendingSnapshot = snapshot
        needsRebuild = true
        engineLength = -1
        tokens = DecorationSet()
        covered = NSRange(location: 0, length: 0)
        desired = range
        scheduleSync(delay: 0)
    }

    /// 文档变更:立即平移已有片段,并排队后台增量同步。
    func documentChanged(_ change: DocumentChange, desired range: NSRange) {
        tokens.apply(edits: change.edits)
        covered = Self.mapRange(covered, through: change.edits)
        pendingEdits.append(contentsOf: change.edits)
        pendingSnapshot = change.snapshot
        desired = range
        scheduleSync(delay: 0.012)
    }

    /// 视口移动后确保片段覆盖目标区间。
    func ensureCovered(_ range: NSRange) {
        desired = range
        let lower = max(range.location - 2_000, 0)
        let upper = range.location + range.length + 2_000
        if lower >= covered.location, upper <= covered.location + covered.length { return }
        scheduleSync(delay: 0)
    }

    /// 与行区间相交的片段(按文档顺序)。
    func spans(intersecting range: NSRange) -> [Decoration] {
        guard range.length > 0 else { return [] }
        return tokens.intersecting(TextSpan(location: range.location, length: range.length))
    }

    // MARK: 同步

    private func scheduleSync(delay: TimeInterval) {
        if syncing { dirty = true; return }
        syncing = true
        let token = generation
        Task { @MainActor [weak self] in
            if delay > 0 { try? await Task.sleep(for: .milliseconds(Int(delay * 1000))) }
            await self?.runSync(token: token)
        }
    }

    private func runSync(token: Int) async {
        defer {
            syncing = false
            if dirty {
                dirty = false
                scheduleSync(delay: 0)
            }
        }
        guard token == generation, let snapshot = pendingSnapshot else { return }
        let edits = pendingEdits
        pendingEdits = []
        let range = Self.padded(desired, length: snapshot.length)
        let language = self.language
        // 超大文件:不进后台引擎(全量词法扫描会常驻数百 MB 片段),只对视口附近按行对齐的窗口做词法扫描,
        // 代价与文件大小无关;窗口起点之前的跨行上下文(长块注释、多行字符串)不参与,属于大文件模式的取舍。
        if snapshot.length > HighlightEngine.treeSitterMaxUnits, language != .plain {
            needsRebuild = true
            engineLength = -1
            let spans = await Task.detached(priority: .userInitiated) { Self.lexWindow(snapshot, range: range, language: language) }.value
            guard token == generation else { return }
            if !pendingEdits.isEmpty { dirty = true; return }
            publish(spans: spans, range: range)
            return
        }
        var synced = false
        if !needsRebuild, engineLength >= 0, !edits.isEmpty, edits.allSatisfy({ $0.inserted != nil }) {
            let units = edits.map { TextUnitEdit(location: $0.location, oldLength: $0.oldLength, replacement: Array($0.inserted ?? [])) }
            synced = await engine.applyEdits(units, oldLength: engineLength, newLength: snapshot.length, language: language)
        } else if !needsRebuild, edits.isEmpty, engineLength == snapshot.length {
            synced = true
        }
        if !synced {
            let span = Log.editor.span("语法重建", warnMs: 120, quiet: true, ["chars": "\(snapshot.length)"])
            let text = await Task.detached(priority: .userInitiated) { snapshot.string() }.value
            await engine.rebuild(text: text, language: language)
            span.end()
            // 全量解析会产生大量瞬时分配(文本副本、解析栈);大文件解析完后把空闲页还给系统,常驻内存才不会停在峰值
            if snapshot.length > 400_000 {
                Task.detached(priority: .background) { _ = malloc_zone_pressure_relief(nil, 0) }
            }
        }
        guard token == generation else { return }
        needsRebuild = false
        engineLength = snapshot.length
        let spans = await engine.spans(in: range)
        guard token == generation else { return }
        // 同步期间又有新编辑:结果已过期,留给下一轮。
        if !pendingEdits.isEmpty { dirty = true; return }
        publish(spans: spans, range: range)
    }

    /// 对 `range`(向外扩到整行)做词法扫描,片段坐标还原为文档偏移。
    nonisolated static func lexWindow(_ snapshot: TextRope, range: NSRange, language: SyntaxLanguage) -> [SyntaxSpan] {
        guard snapshot.length > 0, range.length > 0 else { return [] }
        let first = snapshot.line(containing: min(range.location, snapshot.length))
        let last = snapshot.line(containing: min(range.location + range.length, snapshot.length))
        let lower = snapshot.lineStart(first)
        let upper = min(snapshot.lineStart(last) + snapshot.lineLength(last), snapshot.length)
        guard upper > lower else { return [] }
        let text = snapshot.string(in: TextSpan(location: lower, length: upper - lower))
        return SimpleLexer.lex(text, language: language).map { SyntaxSpan(location: $0.location + lower, length: $0.length, kind: $0.kind) }
    }

    /// 把片段落成装饰并通知视图重绘。
    private func publish(spans: [SyntaxSpan], range: NSRange) {
        var items: [Decoration] = []
        items.reserveCapacity(spans.count)
        for (index, span) in spans.enumerated() where span.length > 0 {
            items.append(Decoration(id: index, range: TextSpan(location: span.location, length: span.length),
                                    kind: .custom(Int(span.kind.rawValue)), removesWhenCollapsed: true))
        }
        tokens = DecorationSet()
        tokens.replaceAll(items)
        covered = range
        syncCount += 1
        onUpdate?()
    }

    static func padded(_ range: NSRange, length: Int) -> NSRange {
        let lower = max(range.location - padding, 0)
        let upper = min(range.location + range.length + padding, length)
        return NSRange(location: lower, length: max(upper - lower, 0))
    }

    private static func mapRange(_ range: NSRange, through edits: [AppliedEdit]) -> NSRange {
        let start = OffsetMapping.map(range.location, through: edits, bias: .right)
        let end = OffsetMapping.map(range.location + range.length, through: edits, bias: .left)
        return NSRange(location: start, length: max(end - start, 0))
    }
}
