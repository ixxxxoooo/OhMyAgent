// @author ixxxxoooo
// 欢迎页:工作台还没有项目时显示,提供「打开项目」与最近项目。

import IconKit
import ChatKit
import DesignSystem
import SwiftUI
import WorkbenchKit

struct WelcomeView: View {
    let workbench: WorkbenchModel

    var body: some View {
        VStack(spacing: 18) {
            Image.om("sparkles", size: 40, weight: .light)
                .foregroundStyle(OMColors.accent)
            Text("打开一个项目开始")
                .font(OMFonts.title)
            Text("添加项目目录后,可以直接在该项目下向 Claude Code 提问;也可以不打开项目,直接开始一个通用会话。")
                .font(OMFonts.small)
                .foregroundStyle(OMColors.secondaryText)
                .multilineTextAlignment(.center)
            Button {
                if let url = WorkspaceStore.chooseDirectory() { AppActions.shared.openWorkspace(url) }
            } label: {
                Label("打开项目…", om: "folder.badge.plus")
            }
            .buttonStyle(.omPrimary)
            .controlSize(.large)
            Button {
                workbench.newGeneralConversation()
            } label: {
                Label("开始会话(无需项目)", om: "message-circle-plus")
            }
            .buttonStyle(.omSecondary)
            let recents = RecentStore.projects().prefix(5)
            if !recents.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("最近项目").font(OMFonts.caption).foregroundStyle(OMColors.secondaryText)
                    ForEach(Array(recents), id: \.self) { path in
                        Button {
                            AppActions.shared.openWorkspace(URL(fileURLWithPath: path))
                        } label: {
                            HStack {
                                Image.om("folder")
                                Text((path as NSString).lastPathComponent)
                                Text((path as NSString).abbreviatingWithTildeInPath)
                                    .foregroundStyle(OMColors.secondaryText)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .font(OMFonts.small)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 8)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(OMColors.surface)
    }
}
