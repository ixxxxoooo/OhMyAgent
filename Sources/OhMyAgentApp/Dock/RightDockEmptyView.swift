// @author ixxxxoooo
// 右栏空状态:没有任何标签时,以列表列出常用入口(资源管理器、搜索、源代码管理、终端、浏览器、输出)。

import DesignSystem
import IconKit
import SwiftUI
import WorkbenchKit

/// 右栏没有任何标签时的空状态:标题 + 常用入口列表,点击即在右栏打开(终端/浏览器已有则复用)。
struct RightDockEmptyView: View {
    let workbench: WorkbenchModel

    /// 一个常用入口。
    private struct Entry: Identifiable {
        /// `AppActions.focusRightTab` 的参数
        let id: String
        let icon: String
        let title: String
        let detail: String
    }

    /// 常用入口(顺序与右栏「+」菜单一致的分组:浏览类在前,运行类在后)。
    private var entries: [Entry] {
        [
            Entry(id: "files", icon: "folder", title: String(localized: "资源管理器"), detail: String(localized: "浏览项目文件")),
            Entry(id: "search", icon: "search", title: String(localized: "搜索"), detail: String(localized: "在项目中查找文本")),
            Entry(id: "git", icon: "git-branch", title: String(localized: "源代码管理"), detail: String(localized: "查看改动与提交")),
            Entry(id: "terminal", icon: "square-terminal", title: String(localized: "终端"), detail: String(localized: "在项目目录运行命令")),
            Entry(id: "browser", icon: "globe", title: String(localized: "浏览器"), detail: String(localized: "打开网页与本地预览")),
            Entry(id: "output", icon: "file-text", title: String(localized: "输出"), detail: String(localized: "查看运行输出与日志")),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: OMSpacing.md) {
            VStack(alignment: .leading, spacing: OMSpacing.xs) {
                Text("右栏为空").font(OMFonts.body).foregroundStyle(OMColors.secondaryText)
                Text("打开文件、终端或资源管理器,它们会以标签显示在这里")
                    .font(OMFonts.caption).foregroundStyle(OMColors.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, OMSpacing.sm)
            VStack(spacing: 2) {
                ForEach(entries) { entry in
                    EntryRow(icon: entry.icon, title: entry.title, detail: entry.detail) { open(entry.id) }
                }
            }
        }
        .frame(maxWidth: 300)
        .padding(OMSpacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 打开某个入口:终端沿用当前项目的常驻终端,其余交给 `AppActions`(浏览器已有则复用)。
    /// - Parameter kind: 入口 id
    private func open(_ kind: String) {
        if kind == "terminal" {
            workbench.showTerminal()
        } else {
            AppActions.shared.focusRightTab(kind)
        }
    }
}

/// 空状态列表中的一行:图标 + 标题 + 说明,悬停高亮。
private struct EntryRow: View {
    let icon: String
    let title: String
    let detail: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: OMSpacing.sm) {
                Image.om(icon, size: 14)
                    .foregroundStyle(OMColors.secondaryText)
                    .frame(width: 20)
                Text(title).font(OMFonts.body).foregroundStyle(OMColors.primaryText)
                Spacer(minLength: OMSpacing.sm)
                Text(detail).font(OMFonts.caption).foregroundStyle(OMColors.tertiaryText).lineLimit(1)
            }
            .padding(.horizontal, OMSpacing.sm)
            .frame(height: 32)
            .background(hovering ? OMColors.hoverFill : .clear, in: RoundedRectangle(cornerRadius: OMRadius.control, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(title)
        .accessibilityHint(detail)
    }
}
