// @author ixxxxoooo
// 命令面板的命令清单:供中央搜索窗(HubSearch)的「操作」分类使用;快速打开与命令面板入口都转到中央搜索窗。

import AppKit
import DesignSystem
import IconKit
import SwiftUI
import WorkbenchKit

/// 面板模式(兼容旧入口:快速打开 = 搜索窗「文件」,命令面板 = 「操作」)。
enum PaletteMode { case files, commands }

/// 旧命令面板入口的转发器:统一打开中央搜索窗。
@MainActor
enum PaletteModel {
    /// 打开中央搜索窗并定位到对应分类。
    /// - Parameters:
    ///   - mode: 快速打开或命令面板
    ///   - workbench: 工作台
    static func present(_ mode: PaletteMode, workbench: WorkbenchModel) {
        HubModel.shared.present(mode == .files ? .files : .actions, workbench: workbench)
    }
}

/// 一条可由命令面板执行的命令。
struct PaletteCommand {
    let id: String
    let title: String
    let icon: String
    let shortcut: String?
    let run: @MainActor () -> Void
}

@MainActor
enum PaletteCommands {
    /// 全部命令(随工作台状态生成)。
    static func all(workbench: WorkbenchModel) -> [PaletteCommand] {
        let store = ShortcutStore.shared
        func key(_ a: ShortcutAction) -> String { store.binding(for: a).display }
        return [
            PaletteCommand(id: "new", title: String(localized: "新对话"), icon: "square-pen", shortcut: key(.newConversation)) {
                if let id = workbench.selectedProjectID { workbench.newConversation(in: id) }
            },
            PaletteCommand(id: "open", title: String(localized: "打开项目…"), icon: "folder-plus", shortcut: key(.openWorkspace)) {
                if let url = WorkspaceStore.chooseDirectory() { AppActions.shared.openWorkspace(url) }
            },
            PaletteCommand(id: "quickOpen", title: String(localized: "快速打开文件"), icon: "file-search", shortcut: key(.quickOpen)) {
                PaletteModel.present(.files, workbench: workbench)
            },
            PaletteCommand(id: "search", title: String(localized: "在文件中搜索"), icon: "text-search", shortcut: key(.globalSearch)) {
                workbench.showRight(.search); SearchModel.shared.requestFocus()
            },
            PaletteCommand(id: "save", title: String(localized: "保存文件"), icon: "save", shortcut: key(.saveFile)) { AppActions.shared.saveActiveFile() },
            PaletteCommand(id: "saveAll", title: String(localized: "保存全部文件"), icon: "save", shortcut: nil) { AppActions.shared.saveAllFiles() },
            PaletteCommand(id: "gitHistory", title: String(localized: "显示 Git 历史"), icon: "git-graph", shortcut: nil) {
                if let id = workbench.selectedProjectID { workbench.openHistory(project: id) }
            },
            PaletteCommand(id: "fileHistory", title: String(localized: "查看当前文件的 Git 历史"), icon: "clock", shortcut: nil) {
                if let id = workbench.selectedProjectID, case .file(let path)? = workbench.focusedActiveTab?.kind { workbench.openHistory(project: id, path: path) }
            },
            PaletteCommand(id: "fileBlame", title: String(localized: "查看当前文件的 Git Blame"), icon: "user", shortcut: nil) {
                if case .file(let path)? = workbench.focusedActiveTab?.kind { workbench.openBlame(path) }
            },
            PaletteCommand(id: "terminal", title: String(localized: "新建终端"), icon: "square-terminal", shortcut: key(.newTerminal)) { AppActions.shared.newTerminal() },
            PaletteCommand(id: "terminal-new-tab", title: String(localized: "新建终端标签"), icon: "square-terminal", shortcut: nil) { AppActions.shared.openTerminal() },
            PaletteCommand(id: "terminal-next", title: String(localized: "下一个终端"), icon: "chevron-right", shortcut: nil) { AppActions.shared.cycleTerminal(1) },
            PaletteCommand(id: "terminal-previous", title: String(localized: "上一个终端"), icon: "chevron-left", shortcut: nil) { AppActions.shared.cycleTerminal(-1) },
            PaletteCommand(id: "terminal-close", title: String(localized: "关闭当前终端"), icon: "x", shortcut: nil) { AppActions.shared.closeActiveTerminal() },
            PaletteCommand(id: "explorer", title: String(localized: "显示文件资源管理器"), icon: "folder", shortcut: nil) { workbench.showRight(.files) },
            PaletteCommand(id: "gitPane", title: String(localized: "显示 Git"), icon: "git-branch", shortcut: nil) { workbench.showRight(.git) },
            PaletteCommand(id: "changesTab", title: String(localized: "在标签中查看本轮改动"), icon: "file-diff", shortcut: nil) {
                if let id = workbench.selectedProjectID { workbench.openChanges(project: id) }
            },
            PaletteCommand(id: "left", title: WorkbenchPanelNames.toggleTitle(.sidebar, visible: workbench.layout.leftVisible), icon: workbench.layout.placement.sidebarSide == .left ? "panel-left" : "panel-right", shortcut: key(.toggleSidebar)) { workbench.toggleLeft() },
            PaletteCommand(id: "right", title: WorkbenchPanelNames.toggleTitle(.tools, visible: workbench.layout.rightVisible), icon: workbench.layout.placement.toolsSide == .left ? "panel-left" : "panel-right", shortcut: key(.toggleInspector)) { workbench.toggleRight() },
            workbench.layout.placement.terminal == .bottom
                ? PaletteCommand(id: "bottom", title: workbench.layout.bottomVisible ? String(localized: "隐藏底部面板") : String(localized: "显示底部面板"), icon: "panel-bottom", shortcut: key(.togglePanel)) { workbench.toggleBottom() }
                : PaletteCommand(id: "bottom", title: workbench.isTerminalShown ? String(localized: "隐藏终端") : String(localized: "显示终端"), icon: "square-terminal", shortcut: key(.togglePanel)) { workbench.toggleTerminal() },
            PaletteCommand(id: "automation", title: String(localized: "打开自动化"), icon: "workflow", shortcut: nil) { workbench.openAutomation() },
            PaletteCommand(id: "customize", title: String(localized: "打开自定义"), icon: "sliders-horizontal", shortcut: nil) { workbench.openCustomize() },
            PaletteCommand(id: "canvas", title: String(localized: "打开画布…"), icon: "chart-column", shortcut: nil) { HubModel.shared.present(.canvases, workbench: workbench) },
            PaletteCommand(id: "output", title: workbench.isOutputShown ? String(localized: "隐藏输出面板") : String(localized: "显示输出面板"), icon: "panel-bottom", shortcut: nil) {
                workbench.toggleOutput()
            },
            PaletteCommand(id: "resetLayout", title: String(localized: "恢复默认布局"), icon: "undo-2", shortcut: nil) { workbench.resetLayout() },
            PaletteCommand(id: "settings", title: String(localized: "设置…"), icon: "settings", shortcut: "⌘,") { AppActions.shared.openSettings() },
            PaletteCommand(id: "themePicker", title: String(localized: "切换颜色主题…"), icon: "paintbrush", shortcut: nil) { HubModel.shared.presentThemes(workbench: workbench) },
            PaletteCommand(id: "tools", title: String(localized: "工具与扩展…"), icon: "puzzle", shortcut: key(.extensions)) { workbench.openCustomize() },
            PaletteCommand(id: "shortcuts", title: String(localized: "快捷键设置"), icon: "keyboard", shortcut: nil) { AppActions.shared.openSettings(page: .shortcuts) },
        ]
    }
}
