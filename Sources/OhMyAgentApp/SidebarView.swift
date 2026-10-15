// @author ygw
// 侧栏:工作区、当前对话与连接信息。会话历史在 M4 接入 `session/list`。

import ChatKit
import DesignSystem
import SwiftUI

/// 玻璃侧栏(NavigationSplitView 在 macOS 27 自动获得 Liquid Glass 外观)。
struct SidebarView: View {
    let model: SessionModel

    var body: some View {
        List {
            Section("工作区") {
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.workspace.lastPathComponent).lineLimit(1)
                        Text(model.workspace.abbreviatingHome)
                            .font(OMFonts.caption)
                            .foregroundStyle(OMColors.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                } icon: {
                    Image(systemName: "folder")
                }
            }
            Section("对话") {
                Label {
                    Text(model.sessionTitle ?? "当前对话").lineLimit(1)
                } icon: {
                    Image(systemName: model.isRunning ? "ellipsis.bubble" : "bubble.left")
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            footer
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                OMStatusDot(statusDot)
                Text(statusText).font(OMFonts.small)
            }
            if let auth = model.authStatus {
                Text(auth)
                    .font(OMFonts.caption)
                    .foregroundStyle(OMColors.secondaryText)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var statusDot: OMStatusDot.State {
        switch model.phase {
        case .idle: return .idle
        case .connecting: return .warning
        case .ready: return .success
        case .failed: return .failure
        }
    }

    private var statusText: String {
        switch model.phase {
        case .idle: return "未连接"
        case .connecting: return "正在启动 \(model.agentName)…"
        case .ready: return "\(model.agentName) 已就绪"
        case .failed: return "\(model.agentName) 未连接"
        }
    }
}
