// @author ixxxxoooo
// 设置 → 网络:连通性测试卡片(逐站点显示耗时,可重新测试)。

import ChatKit
import DesignSystem
import SwiftUI

/// 连通性测试内容(放在设置分组卡片内,自身不带背景)。进入页面时自动测一次。
struct ConnectivityCard: View {
    @State private var results: [String: ConnectivityResult] = [:]
    @State private var running = false
    private let targets = ConnectivityTarget.defaults

    private var reachableCount: Int {
        results.values.filter { if case .reachable = $0 { return true } else { return false } }.count
    }

    /// 摘要文案:测试中 / N 个网站中 M 个可以访问。
    private var summary: String {
        running ? String(localized: "测试中…") : String(localized: "\(targets.count) 个网站中 \(reachableCount) 个可以访问。")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("连通性测试").font(OMFonts.body).foregroundStyle(OMColors.primaryText)
                    Text(verbatim: summary).font(OMFonts.small).foregroundStyle(OMColors.secondaryText)
                }
                Spacer()
                Button { Task { await runTest() } } label: {
                    Label("重新测试", om: "rotate-cw")
                }
                .buttonStyle(.omSecondary)
                .disabled(running)
            }
            .padding(.bottom, OMSpacing.sm)
            ForEach(targets) { target in
                Rectangle().fill(OMColors.hairline).frame(height: 0.5)
                row(target)
            }
        }
        .task { await runTest() }
    }

    private func row(_ target: ConnectivityTarget) -> some View {
        HStack(spacing: OMSpacing.md) {
            Image.om(target.icon, size: 16).foregroundStyle(OMColors.secondaryText).frame(width: 20)
            Text(verbatim: target.name).font(OMFonts.body).foregroundStyle(OMColors.primaryText)
                .frame(width: 96, alignment: .leading)
            Text(verbatim: target.host).font(OMFonts.small).foregroundStyle(OMColors.tertiaryText)
            Spacer()
            resultView(results[target.id] ?? .testing)
        }
        .padding(.vertical, OMSpacing.sm + 2)
    }

    @ViewBuilder
    private func resultView(_ result: ConnectivityResult) -> some View {
        switch result {
        case .testing: OMSpinner(.small)
        case .reachable(let ms): Text(verbatim: "\(ms) ms").font(OMFonts.body).foregroundStyle(OMColors.primaryText)
        case .failed(let message):
            Text(verbatim: message).font(OMFonts.small).foregroundStyle(OMColors.danger).lineLimit(1)
                .omTooltip(message)
        }
    }

    /// 并发测试全部站点并实时刷新结果。
    private func runTest() async {
        guard !running else { return }
        running = true
        results = [:]
        await ConnectivityTest.run(targets) { id, result in
            await MainActor.run { results[id] = result }
        }
        running = false
    }
}
