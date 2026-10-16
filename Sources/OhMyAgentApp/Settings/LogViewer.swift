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
    var minLevel: LogLevel = .info
    var category: LogCategory?
    var search = ""
    var follow = true
    @ObservationIgnored private var task: Task<Void, Never>?
    private let capacity = 5000

    /// 过滤后的条目。
    var filtered: [LogEntry] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        return entries.filter { entry in
            entry.level >= minLevel
                && (category == nil || entry.category == category)
                && (query.isEmpty || entry.line.lowercased().contains(query))
        }
    }

    /// 开始订阅(先载入缓冲里的历史)。
    func start() {
        guard task == nil else { return }
        entries = LogSystem.shared.recent(limit: capacity)
        let lastID = entries.last?.id ?? 0
        let stream = LogSystem.shared.stream()
        task = Task { [weak self] in
            for await entry in stream where entry.id > lastID {
                guard let self else { return }
                self.entries.append(entry)
                if self.entries.count > self.capacity { self.entries.removeFirst(self.entries.count - self.capacity) }
            }
        }
    }

    /// 停止订阅。
    func stop() {
        task?.cancel()
        task = nil
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
                    .help("复制当前筛选的日志")
                    .accessibilityLabel("复制日志")
            }
            .labelsHidden()
            .controlSize(.small)
            .font(OMFonts.small)
            .padding(.horizontal, 8).padding(.vertical, 4)
            Divider()
            ScrollViewReader { proxy in
                let rows = model.filtered
                List(rows) { entry in
                    Text(entry.line)
                        .font(OMFonts.monoSmall)
                        .foregroundStyle(color(for: entry.level))
                        .textSelection(.enabled)
                        .lineLimit(3)
                        .id(entry.id)
                        .listRowSeparator(.hidden)
                }
                .listStyle(.plain)
                .onChange(of: rows.last?.id) { _, id in
                    if model.follow, let id { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    private func color(for level: LogLevel) -> Color {
        switch level {
        case .debug: return OMColors.tertiaryText
        case .info: return OMColors.primaryText
        case .warning: return OMColors.warning
        case .error: return OMColors.danger
        }
    }
}
