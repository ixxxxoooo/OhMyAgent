// @author ixxxxoooo
// 容量指标注册:把最可能导致内存增长的集合与缓存接到 `GaugeRegistry`,
// 资源采样时随「容量快照」日志输出,事后可对照 footprint 曲线判断是哪一类数据在增长。

import ChatKit
import EditorKit
import Foundation
import LSPKit
import Synchronization
import WorkbenchKit
import OMLog

/// 容量指标注册入口。
@MainActor
enum PerfGauges {
    /// 语言服务器数量(actor 属性无法同步读取,由采样前刷新钩子推送)。
    private static let lspRunning = Mutex(0)

    /// 一个会话时间线(含子 Agent 内部时间线)的规模。
    struct TimelineSize: Equatable {
        var entries = 0
        var textBytes = 0
        var imageBytes = 0
        var tools = 0

        static func + (lhs: TimelineSize, rhs: TimelineSize) -> TimelineSize {
            TimelineSize(entries: lhs.entries + rhs.entries, textBytes: lhs.textBytes + rhs.textBytes, imageBytes: lhs.imageBytes + rhs.imageBytes, tools: lhs.tools + rhs.tools)
        }
    }

    /// 递归统计时间线规模(条目数、文本字节、图片附件字节、工具条目数)。
    /// - Parameter store: 时间线
    /// - Returns: 规模
    static func size(of store: TimelineStore) -> TimelineSize {
        var total = TimelineSize()
        for entry in store.entries {
            total.entries += 1
            total.textBytes += entry.text.utf8.count + (entry.detail?.utf8.count ?? 0)
            total.imageBytes += entry.attachments.reduce(0) { $0 + $1.data.count }
            if entry.kind == .tool { total.tools += 1 }
            if let child = entry.childStore { total = total + size(of: child) }
        }
        return total
    }

    /// 各会话时间线规模的短期缓存:一次采样里 5 个时间线指标共用一次遍历(此前每个指标各遍历一遍全部时间线)。
    private static var sizeCache: (at: ContinuousClock.Instant, sizes: [TimelineSize])?

    /// 全部会话的时间线规模(1 秒内复用缓存)。
    /// - Parameter workbench: 工作台模型
    private static func timelineSizes(_ workbench: WorkbenchModel) -> [TimelineSize] {
        let now = ContinuousClock.now
        if let cache = sizeCache, now - cache.at < .seconds(1) { return cache.sizes }
        let sizes = workbench.allSessions.map { size(of: $0.timeline) }
        sizeCache = (now, sizes)
        return sizes
    }

    /// 注册全部指标(应用启动时调用一次)。
    /// - Parameter workbench: 工作台模型
    static func register(workbench: WorkbenchModel) {
        let gauges = GaugeRegistry.shared
        gauges.registerMain("sessions.count") { workbench.conversations.count }
        gauges.registerMain("sessions.busy") { workbench.allSessions.filter { $0.isRunning }.count }
        gauges.registerMain("sessions.live") { workbench.allSessions.filter { $0.phase == .ready || $0.phase == .connecting }.count }
        gauges.registerMain("sessions.hibernated") { workbench.allSessions.filter { $0.isHibernated }.count }
        gauges.registerMain("timeline.entries") { timelineSizes(workbench).reduce(0) { $0 + $1.entries } }
        gauges.registerMain("timeline.textKB") { timelineSizes(workbench).reduce(0) { $0 + $1.textBytes } / 1024 }
        gauges.registerMain("timeline.imageKB") { timelineSizes(workbench).reduce(0) { $0 + $1.imageBytes } / 1024 }
        gauges.registerMain("timeline.tools") { timelineSizes(workbench).reduce(0) { $0 + $1.tools } }
        gauges.registerMain("timeline.maxEntries") { timelineSizes(workbench).map(\.entries).max() ?? 0 }
        gauges.registerMain("engine.standby") { workbench.warmPool.standbyCount }
        gauges.registerMain("cache.markdown.hits") { MarkdownCache.hits }
        gauges.registerMain("cache.markdown.misses") { MarkdownCache.misses }
        gauges.registerMain("cache.markdown.streamReparse") { MarkdownCache.streamingReparses }
        gauges.registerMain("cache.markdown.incremental") { MarkdownCache.incrementalParses }
        gauges.registerMain("cache.attachmentImage.hits") { AttachmentImageCache.hits }
        gauges.registerMain("cache.attachmentImage.misses") { AttachmentImageCache.misses }
        gauges.registerMain("cache.mermaidPreview.sources") { MermaidPreviewStore.shared.sources.count }
        gauges.registerMain("files.openDocuments") { FileDocumentStore.shared.documents.count }
        gauges.registerMain("cache.highlight.hits") { CodeHighlighter.cacheStats.hits }
        gauges.registerMain("cache.highlight.misses") { CodeHighlighter.cacheStats.misses }
        gauges.registerMain("lsp.running") { lspRunning.withLock { $0 } }
    }

    /// 资源采样前的刷新:主 actor 指标求值,并拉取 actor 隔离的 LSP 数量。
    static func refresh() async {
        GaugeRegistry.shared.refreshMain()
        let count = await LSPManager.shared.runningCount
        lspRunning.withLock { $0 = count }
    }
}
