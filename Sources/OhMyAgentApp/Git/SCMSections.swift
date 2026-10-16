// @author ygw
// Git 页(源代码管理)里的两个可折叠分区,对齐 VSCode/Cursor 的信息架构:
// ① 「本轮 Agent 改动」:当前会话最近一次改动汇总(原右栏「改动」页并入此处);
// ② 「提交图谱」:最近提交与泳道图(原先只能从「更多」菜单打开历史标签),点击进入完整历史标签。

import AppKit
import ChatKit
import DesignSystem
import GitKit
import IconKit
import SwiftUI
import WorkbenchKit

/// 可折叠分区标题:左侧箭头 + 标题 + 数量,右侧放操作。
private struct CollapsibleHeader<Actions: View>: View {
    let title: LocalizedStringKey
    let count: Int?
    @Binding var expanded: Bool
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(spacing: 4) {
            Button {
                omWithAnimation(.snappy(duration: 0.16)) { expanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image.om("chevron-right", size: 10, weight: .bold)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .frame(width: 12)
                    Text(title).font(OMFonts.caption.weight(.semibold))
                    if let count { Text("\(count)").font(OMFonts.caption).foregroundStyle(OMColors.tertiaryText) }
                    Spacer(minLength: 0)
                }
                .foregroundStyle(OMColors.secondaryText)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(expanded ? "收起" : "展开")
            actions()
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
    }
}

/// 「本轮 Agent 改动」分区:没有改动汇总时不显示。
struct AgentChangesSection: View {
    let workbench: WorkbenchModel
    @State private var expanded = true

    var body: some View {
        if let model = workbench.activeSession,
           let entry = model.timeline.entries.last(where: { $0.kind == .changes && !$0.changes.isEmpty }) {
            VStack(alignment: .leading, spacing: 0) {
                CollapsibleHeader(title: "本轮 Agent 改动", count: entry.changes.count, expanded: $expanded) { EmptyView() }
                if expanded {
                    ChangesSummaryView(entry: entry)
                        .environment(model)
                        .padding(.horizontal, 8)
                        .padding(.bottom, 8)
                }
            }
        }
    }
}

/// 「提交图谱」分区:最近 30 个提交(含所有分支)的泳道图;点击打开完整历史标签。
struct GitGraphSection: View {
    let workbench: WorkbenchModel
    let model: GitModel
    @State private var expanded = true
    @State private var rows: [GitGraphRow] = []
    @State private var failed = false
    private static let limit = 30

    /// 状态变化(分支切换、提交/推送/拉取、工作区变干净)时重新取数。
    private var reloadKey: String {
        "\(model.status.branch ?? "-")#\(model.status.ahead)#\(model.status.behind)#\(model.status.isClean)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CollapsibleHeader(title: "提交图谱", count: nil, expanded: $expanded) {
                Button { workbench.openHistory(project: model.projectPath) } label: {
                    Image.om("external-link", size: 12)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(OMColors.secondaryText)
                .help("在标签页打开完整历史")
                .accessibilityLabel("打开完整提交历史")
            }
            if expanded {
                if rows.isEmpty {
                    Text(failed ? "无法读取提交历史" : "还没有提交")
                        .font(OMFonts.small)
                        .foregroundStyle(OMColors.tertiaryText)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                } else {
                    let laneWidth = CGFloat(max(1, rows.map(\.laneCount).max() ?? 1)) * 14 + 10
                    VStack(spacing: 0) {
                        ForEach(rows) { row in
                            CommitRow(row: row, laneWidth: laneWidth, isSelected: false, compact: true)
                                .onTapGesture { workbench.openHistory(project: model.projectPath) }
                                .accessibilityElement(children: .combine)
                                .accessibilityAddTraits(.isButton)
                                .contextMenu {
                                    Button("拷贝提交哈希") {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(row.commit.hash, forType: .string)
                                    }
                                    Button("打开完整历史") { workbench.openHistory(project: model.projectPath) }
                                }
                        }
                    }
                }
            }
        }
        .padding(.bottom, 8)
        .task(id: reloadKey) { await load() }
    }

    private func load() async {
        guard let repo = await GitRepository.discover(from: model.projectPath) else {
            rows = []
            return
        }
        do {
            let commits = try await repo.log(limit: Self.limit, path: nil, all: true)
            rows = GitGraph.layout(commits)
            failed = false
        } catch {
            failed = true
        }
    }
}
