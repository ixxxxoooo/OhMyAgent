// @author ixxxxoooo
// 「编辑工作区…」对话框:修改名称,增删附加文件夹(多文件夹工作区)。

import AppKit
import DesignSystem
import IconKit
import SwiftUI
import WorkbenchKit

/// 编辑工作区的草稿状态。
@MainActor
@Observable
private final class WorkspaceDraft {
    var name: String
    var folders: [String]
    var error: String?
    init(name: String, folders: [String]) { self.name = name; self.folders = folders }
}

/// 编辑工作区。
@MainActor
enum WorkspaceEditor {
    /// 弹出对话框;确认后写入项目。
    /// - Parameters:
    ///   - project: 目标项目
    ///   - workbench: 工作台模型
    static func present(project: ProjectEntry, workbench: WorkbenchModel) {
        let draft = WorkspaceDraft(name: project.name, folders: project.extraFolders)
        let code = OMModal.run(width: 460) { handle in
            WorkspaceEditorCard(primary: project.id, draft: draft, finish: { handle.finish($0) })
        }
        guard code == 0 else { return }
        let trimmed = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != project.name { workbench.renameProject(project.id, to: trimmed) }
        for path in project.extraFolders where !draft.folders.contains(path) { workbench.removeFolder(path, from: project.id) }
        for path in draft.folders where !project.extraFolders.contains(path) { workbench.addFolder(path, to: project.id) }
        // 文件索引、监听与文件树随工作区变化重建
        if workbench.selectedProjectID == project.id {
            WorkspaceIndexModel.shared.refresh(root: project.id)
            ExplorerModel.shared.bump()
        }
    }
}

/// 编辑工作区卡片。
private struct WorkspaceEditorCard: View {
    let primary: String
    @Bindable var draft: WorkspaceDraft
    let finish: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("编辑工作区").font(OMFonts.title).foregroundStyle(OMColors.primaryText)
            Text("工作区可以包含多个文件夹:Agent、搜索、文件树与 Git 面板会同时覆盖它们。")
                .font(OMFonts.small).foregroundStyle(OMColors.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                Text("名称").font(OMFonts.caption).foregroundStyle(OMColors.tertiaryText)
                TextField("工作区名称", text: $draft.name)
                    .textFieldStyle(.plain).font(OMFonts.small)
                    .padding(.horizontal, 8).frame(height: 28)
                    .background(OMColors.subtleFill, in: RoundedRectangle(cornerRadius: OMRadius.control, style: .continuous))
                    .accessibilityLabel("工作区名称")
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("文件夹").font(OMFonts.caption).foregroundStyle(OMColors.tertiaryText)
                VStack(spacing: 0) {
                    folderRow(path: primary, removable: false)
                    ForEach(draft.folders, id: \.self) { path in
                        Divider().overlay(OMColors.hairline)
                        folderRow(path: path, removable: true)
                    }
                }
                .background(OMColors.subtleFill, in: RoundedRectangle(cornerRadius: OMRadius.control, style: .continuous))
            }

            HStack(spacing: 8) {
                Button { addFolder() } label: { Label("添加文件夹…", om: "folder-plus") }
                    .buttonStyle(.omSecondary)
                if let error = draft.error {
                    Text(error).font(OMFonts.caption).foregroundStyle(OMColors.danger).lineLimit(2)
                }
            }
            Text("新增或移除的文件夹对之后开启的会话生效;已在运行的会话需要重新打开。")
                .font(OMFonts.caption).foregroundStyle(OMColors.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button("取消") { finish(-1) }.buttonStyle(OMButtonStyle(.secondary, size: .regular))
                Spacer()
                Button("完成") { finish(0) }
                    .buttonStyle(OMButtonStyle(.primary, size: .regular))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }

    /// 一行文件夹。
    private func folderRow(path: String, removable: Bool) -> some View {
        HStack(spacing: 8) {
            Image.om("folder", size: 14).foregroundStyle(OMColors.secondaryText)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Text(verbatim: (path as NSString).lastPathComponent).font(OMFonts.small).foregroundStyle(OMColors.primaryText).lineLimit(1)
                }
                Text(verbatim: (path as NSString).abbreviatingWithTildeInPath)
                    .font(OMFonts.caption).foregroundStyle(OMColors.tertiaryText).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if removable {
                Button {
                    draft.folders.removeAll { $0 == path }
                    draft.error = nil
                } label: {
                    Image.om("x", size: 12).frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(OMColors.secondaryText)
                .omTooltip("从工作区移除")
                .accessibilityLabel("从工作区移除")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    /// 选择并校验要添加的文件夹。
    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "添加")
        guard panel.runModal() == .OK else { return }
        draft.error = nil
        for url in panel.urls {
            switch WorkspaceFolders.validate(url.path, primary: primary, existing: draft.folders) {
            case .success(let path): draft.folders.append(path)
            case .failure(let error): draft.error = error.message
            }
        }
    }
}
