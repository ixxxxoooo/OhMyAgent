// @author ygw
// 侧栏:工作区、当前对话、历史会话(session/list)与账号/连接信息。

import ACPKit
import ChatKit
import DesignSystem
import SwiftUI

/// 玻璃侧栏(NavigationSplitView 在 macOS 27 自动获得 Liquid Glass 外观)。
struct SidebarView: View {
    let model: SessionModel

    /// 历史会话(不含当前会话)
    private var history: [SessionSummary] {
        model.history.filter { $0.sessionId != model.sessionId }
    }

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
                    Text(model.sessionTitle ?? String(localized: "当前对话")).lineLimit(1)
                } icon: {
                    Image(systemName: model.isRunning ? "ellipsis.bubble" : "bubble.left")
                }
            }
            if !history.isEmpty {
                Section("历史") {
                    ForEach(history) { item in
                        HistoryRow(item: item)
                            .contentShape(Rectangle())
                            .onTapGesture { model.openSession(item) }
                            .contextMenu {
                                Button("打开") { model.openSession(item) }
                                if model.capabilities.canDelete {
                                    Divider()
                                    Button("删除", role: .destructive) { model.deleteSession(item) }
                                }
                            }
                    }
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
            accountMenu
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// 账号菜单:显示登录状态,提供 Agent 通告的登录方式与退出登录。
    @ViewBuilder
    private var accountMenu: some View {
        if model.authStatus != nil || !model.authMethods.isEmpty || model.capabilities.canLogout {
            Menu {
                ForEach(model.authMethods) { method in
                    Button("使用「\(method.name)」登录") { model.authenticate(method) }
                }
                if model.capabilities.canLogout {
                    Divider()
                    Button("退出登录", role: .destructive) { model.logout() }
                }
            } label: {
                Label(model.authStatus ?? String(localized: "账号"), systemImage: "person.crop.circle")
                    .font(OMFonts.caption)
                    .lineLimit(1)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .foregroundStyle(OMColors.secondaryText)
            .disabled(model.phase != .ready)
        }
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
        case .idle: return String(localized: "未连接")
        case .connecting: return String(localized: "正在启动 \(model.agentName)…")
        case .ready: return String(localized: "\(model.agentName) 已就绪")
        case .failed: return String(localized: "\(model.agentName) 未连接")
        }
    }
}

/// 历史会话行。
struct HistoryRow: View {
    let item: SessionSummary

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title ?? String(localized: "未命名对话")).lineLimit(1)
                if let time = relativeTime {
                    Text(time).font(OMFonts.caption).foregroundStyle(OMColors.secondaryText)
                }
            }
        } icon: {
            Image(systemName: "bubble.left")
        }
        .accessibilityElement(children: .combine)
    }

    private var relativeTime: String? {
        guard let text = item.updatedAt else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
        return date?.formatted(.relative(presentation: .named))
    }
}
