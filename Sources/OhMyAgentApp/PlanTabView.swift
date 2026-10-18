// @author ixxxxoooo
// 计划标签页(对标 Cursor 3.1 的 Plan 标签):像文件一样可靠加载、跟踪未保存状态、保存、复制、导出 Markdown。
// 顶部工具栏:标题 / 未保存标记 / 预览-源码切换 / Build / 保存 / 重新读取 / 复制 / 导出 / 在 Finder 中显示。

import AppKit
import ChatKit
import DesignSystem
import IconKit
import OMLog
import SwiftUI
import UniformTypeIdentifiers

/// 标签页视图模式。
enum PlanViewMode: Hashable { case preview, source }

struct PlanTabView: View {
    /// 计划文件(`*.plan.md`)的绝对路径
    let path: String
    @State private var text = ""
    @State private var savedText = ""
    @State private var loading = true
    @State private var errorText: String?
    @State private var saveError: String?
    @State private var mode = PlanViewMode.preview

    private var url: URL { URL(fileURLWithPath: path) }
    private var document: PlanDocument { PlanDocument.parse(markdown: text) }
    /// 是否有未保存的修改
    private var isDirty: Bool { text != savedText }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().opacity(0.5)
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(OMColors.surface)
        .task(id: path) { await load() }
    }

    // MARK: 工具栏

    private var toolbar: some View {
        HStack(spacing: 10) {
            Image.om("list-todo", size: 14).foregroundStyle(OMColors.accent)
            Text(verbatim: loading || errorText != nil ? (path as NSString).lastPathComponent : document.name).font(OMFonts.title).lineLimit(1)
            if isDirty { OMTag(String(localized: "未保存"), tint: OMColors.warning) }
            Spacer(minLength: 8)
            OMCompactSegmented(
                options: [(value: PlanViewMode.preview, title: String(localized: "预览")), (value: PlanViewMode.source, title: String(localized: "源码"))],
                selection: mode, accessibilityName: String(localized: "计划视图模式")
            ) { mode = $0 }
            Button("Build") { PlanActions.buildInNewSession(document, fileURL: url, projectID: nil) }
                .buttonStyle(OMButtonStyle(.warm))
                .disabled(loading || errorText != nil)
            Button("保存") { Task { await save() } }
                .buttonStyle(.omSecondary)
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!isDirty)
            toolButton("rotate-cw", help: String(localized: "重新读取")) { Task { await load() } }
            OMCopyButton(help: String(localized: "复制计划")) { document.body }
                .buttonStyle(.omIcon)
            toolButton("file-down", help: String(localized: "导出为 Markdown")) { exportMarkdown() }
            toolButton("folder-open", help: String(localized: "在 Finder 中显示")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
        .padding(.horizontal, 16)
        .frame(height: 40)
    }

    private func toolButton(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image.om(icon, size: 13) }
            .buttonStyle(.omIcon)
            .omTooltip(help)
            .accessibilityLabel(help)
            .disabled(loading || errorText != nil)
    }

    // MARK: 内容

    @ViewBuilder
    private var content: some View {
        if let errorText {
            VStack(spacing: 10) {
                Image.om("triangle-alert", size: 24).foregroundStyle(OMColors.tertiaryText)
                Text(verbatim: errorText).font(OMFonts.body).foregroundStyle(OMColors.secondaryText)
                Button("重试") { Task { await load() } }.buttonStyle(.omSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if loading {
            OMSpinner(.regular).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                if let saveError {
                    Text(verbatim: saveError)
                        .font(OMFonts.small).foregroundStyle(OMColors.danger)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 28).padding(.vertical, 6)
                }
                switch mode {
                case .preview: preview
                case .source: source
                }
            }
        }
    }

    private var preview: some View {
        let plan = document
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if !plan.overview.isEmpty {
                    Text(plan.overview).font(OMFonts.body).foregroundStyle(OMColors.secondaryText).textSelection(.enabled)
                }
                if !plan.todos.isEmpty {
                    PlanTodoList(todos: plan.todos)
                    Divider().overlay(OMColors.hairline)
                }
                MarkdownView(text: plan.body)
            }
            .padding(.horizontal, 28).padding(.vertical, 20)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
    }

    private var source: some View {
        TextEditor(text: $text)
            .font(OMFonts.mono)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 24).padding(.vertical, 12)
    }

    // MARK: 动作

    /// 后台读盘(不阻塞主线程);有未保存修改时不覆盖。
    private func load() async {
        if isDirty { saveError = String(localized: "有未保存的修改,已跳过重新读取;请先保存或还原。"); return }
        let target = url
        loading = text.isEmpty
        let result: Result<String, Error> = await Task.detached(priority: .userInitiated) {
            do { return .success(try String(contentsOf: target, encoding: .utf8)) } catch { return .failure(error) }
        }.value
        loading = false
        switch result {
        case .success(let value):
            text = value
            savedText = value
            errorText = nil
            saveError = nil
        case .failure(let error):
            if text.isEmpty { errorText = String(localized: "无法读取计划文件:\(error.localizedDescription)") }
            Log.ui.warning("计划文件加载失败", ["path": path, "error": error.localizedDescription])
        }
    }

    /// 保存当前文本到计划文件。
    private func save() async {
        let target = url
        let content = text
        let failure: String? = await Task.detached(priority: .userInitiated) {
            do { try content.write(to: target, atomically: true, encoding: .utf8); return nil } catch { return error.localizedDescription }
        }.value
        if let failure {
            saveError = String(localized: "保存失败:\(failure)")
            Log.ui.warning("计划文件保存失败", ["path": path, "error": failure])
        } else {
            savedText = content
            saveError = nil
        }
    }

    /// 导出为不含 YAML 头的 Markdown 文件。
    private func exportMarkdown() {
        let plan = document
        let panel = NSSavePanel()
        panel.nameFieldStringValue = plan.name + ".md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        guard panel.runModal() == .OK, let target = panel.url else { return }
        do { try (plan.body + "\n").write(to: target, atomically: true, encoding: .utf8) } catch {
            saveError = String(localized: "导出失败:\(error.localizedDescription)")
            Log.ui.error("计划导出失败", error: error)
        }
    }
}
