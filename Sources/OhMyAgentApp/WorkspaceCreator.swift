// @author ixxxxoooo
// 「添加工作区…」对话框:一次选择多个文件夹(首个为主目录)并创建多文件夹工作区。

import AppKit
import DesignSystem
import IconKit
import SwiftUI
import WorkbenchKit

/// 新建工作区的草稿状态。
@MainActor
@Observable
private final class WorkspaceCreateDraft {
    var name = ""
    var folders: [String] = []
    var error: String?
}

/// 新建工作区。
@MainActor
enum WorkspaceCreator {
    /// 弹出对话框;确认后以首个文件夹为主目录打开项目,其余作为附加文件夹。
    /// - Parameter workbench: 工作台模型
    static func present(workbench: WorkbenchModel) {
        let draft = WorkspaceCreateDraft()
        let code = OMModal.run(width: 460) { handle in
            WorkspaceCreateCard(draft: draft, finish: { handle.finish($0) })
        }
        guard code == 0, let primary = draft.folders.first else { return }
        AppActions.shared.openWorkspace(URL(fileURLWithPath: primary))
        let trimmed = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { workbench.renameProject(primary, to: trimmed) }
        for path in draft.folders.dropFirst() { _ = workbench.addFolder(path, to: primary) }
        WorkspaceIndexModel.shared.refresh(root: primary)
        ExplorerModel.shared.bump()
    }
}

/// 新建工作区卡片。
private struct WorkspaceCreateCard: View {
    @Bindable var draft: WorkspaceCreateDraft
    let finish: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("添加工作区").font(OMFonts.title).foregroundStyle(OMColors.primaryText)
            Text("选择一个或多个项目文件夹(它们是平级的):Agent、搜索、文件树与 Git 面板会同时覆盖它们。")
                .font(OMFonts.small).foregroundStyle(OMColors.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                Text("名称(可选)").font(OMFonts.caption).foregroundStyle(OMColors.tertiaryText)
                TextField("默认使用第一个文件夹名", text: $draft.name)
                    .textFieldStyle(.plain).font(OMFonts.small)
                    .padding(.horizontal, 8).frame(height: 28)
                    .background(OMColors.subtleFill, in: RoundedRectangle(cornerRadius: OMRadius.control, style: .continuous))
                    .accessibilityLabel("工作区名称")
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("文件夹").font(OMFonts.caption).foregroundStyle(OMColors.tertiaryText)
                if draft.folders.isEmpty {
                    Text("尚未添加文件夹").font(OMFonts.small).foregroundStyle(OMColors.tertiaryText)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(OMColors.subtleFill, in: RoundedRectangle(cornerRadius: OMRadius.control, style: .continuous))
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(draft.folders.enumerated()), id: \.element) { index, path in
                            if index > 0 { Divider().overlay(OMColors.hairline) }
                            folderRow(path: path, isPrimary: index == 0)
                        }
                    }
                    .background(OMColors.subtleFill, in: RoundedRectangle(cornerRadius: OMRadius.control, style: .continuous))
                }
            }

            HStack(spacing: 8) {
                Button { addFolders() } label: { Label("添加文件夹…", om: "folder-plus") }
                    .buttonStyle(.omSecondary)
                if let error = draft.error {
                    Text(error).font(OMFonts.caption).foregroundStyle(OMColors.danger).lineLimit(2)
                }
            }

            HStack(spacing: 8) {
                Button("取消") { finish(-1) }.buttonStyle(OMButtonStyle(.secondary, size: .regular))
                Spacer()
                Button("创建") { finish(0) }
                    .buttonStyle(OMButtonStyle(.primary, size: .regular))
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.folders.isEmpty)
            }
        }
        .padding(20)
    }

    /// 一行文件夹。
    private func folderRow(path: String, isPrimary: Bool) -> some View {
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
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    /// 选择并校验要添加的文件夹(与已选文件夹互不包含、不重复)。
    private func addFolders() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "添加")
        guard panel.runModal() == .OK else { return }
        draft.error = nil
        for url in panel.urls {
            let path = WorkspaceFolders.normalize(url.path)
            guard let primary = draft.folders.first else { draft.folders.append(path); continue }
            switch WorkspaceFolders.validate(path, primary: primary, existing: Array(draft.folders.dropFirst())) {
            case .success(let valid): draft.folders.append(valid)
            case .failure(let error): draft.error = error.message
            }
        }
    }
}
