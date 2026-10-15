// @author ygw
// 状态栏(22pt):左侧 Agent 连接状态与项目路径,右侧运行/未读计数。后续里程碑加入分支、光标位置、LSP 等。

import ChatKit
import DesignSystem
import SwiftUI
import WorkbenchKit

struct StatusBarView: View {
    let workbench: WorkbenchModel
    private let attention = AttentionCenter.shared

    var body: some View {
        HStack(spacing: 12) {
            if let model = workbench.activeSession {
                ConnectionBadge(model: model)
                if case .failed = model.phase {
                    Text("请确认本机已安装 claude 并在终端登录过")
                        .foregroundStyle(OMColors.warning)
                }
            } else {
                Text("未打开项目")
            }
            if let project = workbench.selectedProject {
                Text((project.id as NSString).abbreviatingWithTildeInPath)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            let running = attention.count(of: .running), input = attention.count(of: .needsInput), unread = attention.count(of: .unreadDone)
            if input > 0 { counter(color: .orange, text: String(localized: "\(input) 个等待处理")) }
            if running > 0 { counter(color: .blue, text: String(localized: "\(running) 个运行中")) }
            if unread > 0 { counter(color: .green, text: String(localized: "\(unread) 个未读")) }
        }
        .font(OMFonts.caption)
        .foregroundStyle(OMColors.secondaryText)
        .padding(.horizontal, 12)
        .frame(height: 22)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private func counter(color: Color, text: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text)
        }
    }
}
