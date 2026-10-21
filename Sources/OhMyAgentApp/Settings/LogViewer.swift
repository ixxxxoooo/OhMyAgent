// @author ixxxxoooo
// 日志查看器:实时尾随内存环形缓冲,支持按级别/分类过滤与文本搜索;诊断页与底部「输出」面板共用。

import AppKit
import DesignSystem
import Observation
import OMLog
import SwiftUI

/// 日志查看器模型(主线程)。
@MainActor
@Observable
final class LogViewerModel {
    private(set) var entries: [LogEntry] = []
    var minLevel: LogLevel = .info { didSet { if minLevel != oldValue { refilter() } } }
    var category: LogCategory? { didSet { if category != oldValue { refilter() } } }
    var search = "" { didSet { if search != oldValue { refilter() } } }
    var follow = true
    @ObservationIgnored private var task: Task<Void, Never>?
    private let capacity = 5000
    /// 清空时记下的最大条目 id:重新订阅时只载入更新的条目,已清空的历史不会再回来。
    @ObservationIgnored private var clearedUpTo: UInt64 = 0

    /// 过滤后的条目(增量维护:追加时只检查新条目,过滤条件变化时才整体重算)。
    private(set) var filtered: [LogEntry] = []
    @ObservationIgnored private var queryLower = ""

    /// 条目是否满足当前过滤条件。
    private func matches(_ entry: LogEntry) -> Bool {
        entry.level >= minLevel
            && (category == nil || entry.category == category)
            && (queryLower.isEmpty || entry.line.lowercased().contains(queryLower))
    }

    /// 过滤条件变化后整体重算。
    private func refilter() {
        queryLower = search.trimmingCharacters(in: .whitespaces).lowercased()
        filtered = entries.filter(matches)
    }

    /// 开始订阅(先载入缓冲里的历史)。
    func start() {
        guard task == nil else { return }
        entries = LogSystem.shared.recent(limit: capacity).filter { $0.id > clearedUpTo }
        refilter()
        let lastID = entries.last?.id ?? 0
        let stream = LogSystem.shared.stream()
        task = Task { [weak self] in
            for await entry in stream where entry.id > lastID {
                guard let self else { return }
                self.entries.append(entry)
                if self.matches(entry) { self.filtered.append(entry) }
                if self.entries.count > self.capacity {
                    let dropped = self.entries.count - self.capacity
                    self.entries.removeFirst(dropped)
                    // 被挤出缓冲的最旧条目同步从过滤结果里剔除(按 id 单调递增)
                    if let cutoff = self.entries.first?.id, let keep = self.filtered.firstIndex(where: { $0.id >= cutoff }), keep > 0 {
                        self.filtered.removeFirst(keep)
                    }
                }
            }
        }
    }

    /// 停止订阅。
    func stop() {
        task?.cancel()
        task = nil
    }

    /// 清空视图里的日志(不影响日志文件与全局缓冲)。
    func clear() {
        clearedUpTo = max(clearedUpTo, entries.last?.id ?? 0)
        entries = []
        filtered = []
    }

    /// 复制当前过滤结果到剪贴板。
    func copyFiltered() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(filtered.map(\.line).joined(separator: "\n"), forType: .string)
    }
}

/// 日志查看器视图。
struct LogViewerView: View {
    @State private var model = LogViewerModel()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Picker("级别", selection: $model.minLevel) {
                    ForEach(LogLevel.allCases, id: \.self) { Text($0.label.trimmingCharacters(in: .whitespaces)).tag($0) }
                }
                .frame(width: 84)
                Picker("分类", selection: $model.category) {
                    Text("全部分类").tag(LogCategory?.none)
                    ForEach(LogCategory.allCases, id: \.self) { Text($0.rawValue).tag(LogCategory?.some($0)) }
                }
                .frame(width: 104)
                TextField("搜索", text: $model.search).textFieldStyle(.roundedBorder)
                Toggle("跟随", isOn: $model.follow).toggleStyle(.checkbox)
                Button { model.copyFiltered() } label: { Image.om("copy", size: 13) }
                    .omTooltip("复制当前筛选的日志")
                    .accessibilityLabel("复制日志")
                Button { model.clear() } label: { Image.om("trash", size: 13) }
                    .omTooltip("清空输出")
                    .accessibilityLabel("清空输出")
            }
            .labelsHidden()
            .controlSize(.small)
            .font(OMFonts.small)
            .padding(.horizontal, 8).padding(.vertical, 4)
            Divider()
            LogTableView(rows: model.filtered, follow: model.follow)
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }
}
