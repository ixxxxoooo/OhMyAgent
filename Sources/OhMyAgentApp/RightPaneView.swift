// @author ygw
// 右栏检查器:本轮改动(当前会话最近一次的文件改动汇总)与计划(Agent 最近一次的任务清单)。

import IconKit
import ChatKit
import DesignSystem
import SwiftUI
import WorkbenchKit

struct RightPaneView: View {
    @Bindable var workbench: WorkbenchModel

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $workbench.layout.rightPane) {
                ForEach(RightPane.available, id: \.self) { pane in
                    Text(Self.title(pane)).tag(pane)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)
            Divider()
            if let model = workbench.activeSession {
                content(model: model)
            } else {
                ContentUnavailableView { Label("没有会话", om: "bubble.left", size: 28) } description: { Text("选择一个项目后,这里会显示改动与计划。") }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(OMColors.surface)
    }

    @ViewBuilder
    private func content(model: SessionModel) -> some View {
        switch workbench.layout.rightPane {
        case .changes:
            if let entry = model.timeline.entries.last(where: { $0.kind == .changes && !$0.changes.isEmpty }) {
                ScrollView {
                    ChangesSummaryView(entry: entry)
                        .environment(model)
                        .padding(10)
                }
            } else {
                ContentUnavailableView { Label("暂无改动", om: "doc.on.doc", size: 28) } description: { Text("Agent 修改文件后,这里会列出每个文件的差异。") }
            }
        case .plan:
            if let entry = model.timeline.entries.last(where: { $0.kind == .plan }) {
                ScrollView {
                    PlanView(entry: entry).padding(10)
                }
            } else {
                ContentUnavailableView { Label("暂无计划", om: "checklist", size: 28) } description: { Text("Agent 制定任务计划后会显示在这里。") }
            }
        case .outline, .problems:
            EmptyView()
        }
    }

    private static func title(_ pane: RightPane) -> String {
        switch pane {
        case .changes: return String(localized: "改动")
        case .plan: return String(localized: "计划")
        case .outline: return String(localized: "大纲")
        case .problems: return String(localized: "问题")
        }
    }
}
