// @author ixxxxoooo
// IDE 工作区的编辑器操作:标签关闭(含未保存确认)、保存、切换、重新打开已关闭的标签、窗口关闭前的脏文件确认。

import AppKit
import EditorKit
import IDEKit
import OMLog
import WorkbenchKit

extension IDEWorkspace {
    /// 供 `FileTabView` 使用的宿主。
    var fileHost: IDEFileHost {
        IDEFileHost(
            root: root,
            open: { [weak self] path, line, preview in self?.model.openFile(path, line: line, preview: preview) },
            setDirty: { [weak self] dirty, path in
                self?.model.setDirty(dirty, forFile: path)
                if dirty { self?.scheduleAutoSave() }
            },
            reference: { [weak self] token in self?.addReferenceToChat(token) },
            report: { [weak self] path, diagnostics, text in
                let problems = diagnostics.map { item -> IDEProblem in
                    let position = IDELineMap.lineColumn(utf16Offset: item.range.location, in: text)
                    return IDEProblem(path: path, line: position.line, column: position.column,
                                      severity: IDESeverity(rawValue: item.severity.rawValue) ?? .information, message: item.message)
                }
                self?.model.problems.set(problems, forFile: path)
            },
            caret: { [weak self] path, caret in self?.carets[path] = caret },
            registerLSP: { [weak self] path, controller in self?.registerLSP(controller, for: path) }
        )
    }

    /// 窗口里所有有未保存修改的文件路径。
    var dirtyPaths: [String] {
        model.openFilePaths.filter { FileDocumentStore.shared.documents[$0]?.isDirty == true }
    }

    // MARK: 终端

    /// 新建终端并显示面板。
    func newTerminal() {
        let id = UUID().uuidString
        TerminalStore.shared.register(id: id, directory: TerminalPrefs.load().startDirectoryPath(project: root))
        model.addTerminal(id)
        model.showPanel(.terminal)
    }

    /// 结束终端并从列表移除。
    /// - Parameter id: 终端标识
    func closeTerminal(_ id: String) {
        model.removeTerminal(id)
        TerminalStore.shared.remove(id)
    }

    /// 结束本窗口的全部终端(窗口关闭时调用)。
    func closeAllTerminals() {
        for id in model.terminalIDs { closeTerminal(id) }
    }

    // MARK: 保存

    /// 「延迟保存」模式下,最后一次修改后停顿一秒保存全部;每次修改重置计时。
    func scheduleAutoSave() {
        guard IDEAutoSaveMode.current == .afterDelay else { return }
        autoSaveTask?.cancel()
        autoSaveTask = Task { [weak self] in
            try? await Task.sleep(for: IDEAutoSaveMode.delay)
            guard !Task.isCancelled, let self, IDEAutoSaveMode.current == .afterDelay else { return }
            Log.editor.info("IDE 自动保存", ["files": "\(self.dirtyPaths.count)"])
            self.saveAll()
        }
    }

    /// 窗口失去焦点:「失焦保存」模式下保存全部。
    func autoSaveOnFocusLoss() {
        guard IDEAutoSaveMode.current == .onFocusLoss, !dirtyPaths.isEmpty else { return }
        Log.editor.info("IDE 失焦自动保存", ["files": "\(dirtyPaths.count)"])
        saveAll()
    }

    /// 保存当前聚焦标签的文件。
    func saveActive() {
        guard let path = model.activeFilePath else { return }
        Task {
            _ = await FileDocumentStore.shared.save(path)
            syncDirtyFlags()
            // 保存后服务器已同步新文本,刷新大纲
            try? await Task.sleep(for: .milliseconds(400))
            refreshOutline()
        }
    }

    /// 保存本窗口所有未保存的文件。
    func saveAll() {
        let paths = dirtyPaths
        Task {
            for path in paths { _ = await FileDocumentStore.shared.save(path) }
            syncDirtyFlags()
        }
    }

    /// 把窗口内文件标签的脏标记与文档状态对齐。
    func syncDirtyFlags() {
        for path in model.openFilePaths { model.setDirty(FileDocumentStore.shared.documents[path]?.isDirty ?? false, forFile: path) }
    }

    // MARK: 关闭

    /// 请求关闭标签:固定标签不关;文件有未保存修改且是最后一个指向它的标签时,询问「保存 / 不保存 / 取消」。
    /// - Parameters:
    ///   - tabID: 标签标识
    ///   - force: 为 true 时无视固定状态(菜单「关闭」显式操作)
    func requestClose(_ tabID: UUID, force: Bool = false) {
        guard let tab = model.editor.tab(tabID) else { return }
        if tab.isPinned, !force { return }
        guard case .file(let path) = tab.kind else { finishClose(tab); return }
        let others = model.editor.allTabs.filter { $0.id != tabID && $0.kind == .file(path: path) }
        guard others.isEmpty, FileDocumentStore.shared.documents[path]?.isDirty == true else { finishClose(tab); return }
        let choice = OMDialog.show(
            title: String(localized: "要保存对 \((path as NSString).lastPathComponent) 的修改吗?"),
            message: String(localized: "如果不保存,你的修改将会丢失。"),
            buttons: [.cancel(), .destructive(String(localized: "不保存")), .primary(String(localized: "保存"))]
        ).index
        switch choice {
        case 2:
            Task {
                if await FileDocumentStore.shared.save(path) { FileDocumentStore.shared.discard(path); finishClose(tab) }
            }
        case 1:
            FileDocumentStore.shared.discard(path)
            finishClose(tab)
        default: break
        }
    }

    /// 关闭除某标签外同组的其他标签(逐个确认)。
    /// - Parameter tabID: 保留的标签
    func requestCloseOthers(_ tabID: UUID) {
        guard let group = model.editor.location(of: tabID).flatMap({ model.editor.group($0.group) }) else { return }
        for tab in group.tabs where tab.id != tabID && !tab.isPinned { requestClose(tab.id) }
    }

    /// 关闭聚焦组的当前标签(⌘W)。
    /// - Returns: 是否处理了(没有标签时返回 false,由调用方关窗口)
    @discardableResult
    func closeActiveTab() -> Bool {
        guard let tab = model.editor.focusedGroup?.active else { return false }
        requestClose(tab.id)
        return true
    }

    private func finishClose(_ tab: WorkbenchTab) {
        if case .file = tab.kind { closedStack.append(tab.kind); if closedStack.count > 20 { closedStack.removeFirst() } }
        model.closeTab(tab.id)
    }

    /// 重新打开最近关闭的文件标签(⇧⌘T)。
    func reopenClosed() {
        while let kind = closedStack.popLast() {
            if case .file(let path) = kind, FileManager.default.fileExists(atPath: path) {
                model.openFile(path, preview: false)
                return
            }
        }
    }

    /// 在聚焦组内循环切换标签。
    /// - Parameter step: 步长(1 下一个,-1 上一个)
    func cycleTab(by step: Int) {
        guard let group = model.editor.focusedGroup, group.tabs.count > 1,
              let index = group.tabs.firstIndex(where: { $0.id == group.activeID }) else { return }
        let next = (index + step + group.tabs.count) % group.tabs.count
        var layout = model.editor
        layout.activate(group.tabs[next].id)
        model.editor = layout
    }

    // MARK: 窗口关闭

    /// 窗口关闭前确认所有未保存的文件。
    /// - Returns: 是否允许关闭
    func confirmWindowClose() -> Bool {
        let dirty = dirtyPaths
        guard !dirty.isEmpty else { return true }
        let names = dirty.prefix(5).map { ($0 as NSString).lastPathComponent }.joined(separator: "、")
        let choice = OMDialog.show(
            title: String(localized: "要保存 \(dirty.count) 个文件的修改吗?"),
            message: names + (dirty.count > 5 ? "…" : ""),
            buttons: [.cancel(), .destructive(String(localized: "不保存")), .primary(String(localized: "全部保存"))]
        ).index
        switch choice {
        case 2:
            Task {
                for path in dirty { _ = await FileDocumentStore.shared.save(path) }
                syncDirtyFlags()
                NSApp.sendAction(#selector(NSWindow.performClose(_:)), to: nil, from: nil)
            }
            return false   // 保存完成后由上面的 performClose 再次触发关闭
        case 1:
            for path in dirty { FileDocumentStore.shared.discard(path) }
            return true
        default:
            return false
        }
    }
}

