// @author ixxxxoooo
// 终端/输出面板:作为右栏停靠区(或编辑区)里的普通标签显示、隐藏与切换(无视图)。

import Foundation

@MainActor
public extension WorkbenchModel {
    /// 项目级常驻终端的标识(与终端存储一致;标签关闭/移动位置时进程保持存活)。
    var residentTerminalID: String { "bottom:" + (selectedProjectID ?? NSHomeDirectory()) }

    /// 从常驻终端标识取出项目根(不是常驻终端标识为 nil)。
    /// - Parameter terminalID: 终端标识(`bottom:<项目根>`)
    /// - Returns: 项目根目录
    nonisolated static func residentTerminalRoot(_ terminalID: String) -> String? {
        terminalID.hasPrefix("bottom:") ? String(terminalID.dropFirst("bottom:".count)) : nil
    }

    /// 某项目常驻终端的标识。
    /// - Parameter root: 项目根
    nonisolated static func residentTerminalID(root: String) -> String { "bottom:" + root }

    /// 全部常驻终端标签(两个停靠区,每个项目最多一个)。
    var residentTerminalTabs: [WorkbenchTab] {
        allDockTabs.filter { if case .terminal(let id) = $0.kind { return id.hasPrefix("bottom:") } else { return false } }
    }

    /// 当前项目的常驻终端标签。
    var currentResidentTerminalTab: WorkbenchTab? {
        existingTab(for: .terminal(id: residentTerminalID))?.tab
    }

    /// 当前可见范围内的终端标签(两个停靠区):新建的终端 + 当前项目的常驻终端(其他项目的常驻终端不计),
    /// 按右栏优先、标签顺序排列。
    var terminalTabs: [WorkbenchTab] {
        (rightDock.allTabs + dock.allTabs).filter { tab in
            guard case .terminal(let id) = tab.kind else { return false }
            guard let root = Self.residentTerminalRoot(id) else { return true }
            return root == selectedProjectID
        }
    }

    /// 切换到相邻的终端标签(循环)。
    /// - Parameter step: 1 下一个,-1 上一个
    func cycleTerminalTab(_ step: Int) {
        let tabs = terminalTabs
        guard tabs.count > 1 else { return }
        let currentIndex = tabs.firstIndex { tab in
            guard let host = host(of: tab.id) else { return false }
            return dock(host).group(dock(host).location(of: tab.id)?.group ?? UUID())?.activeID == tab.id
        } ?? -1
        let next = ((currentIndex + step) % tabs.count + tabs.count) % tabs.count
        activateAnyTab(tabs[next].id)
    }

    /// 关闭当前显示的终端标签(没有显示的终端时无操作)。
    func closeActiveTerminalTab() {
        for tab in terminalTabs {
            guard let host = host(of: tab.id), isTabShown(tab.id, in: host) else { continue }
            mutateDock(host) { $0.close(tab.id) }
            syncSelectionFromDock()
            return
        }
    }

    /// 输出标签。
    var outputTabs: [WorkbenchTab] {
        allDockTabs.filter { $0.kind == .preview(id: Self.outputTabID) }
    }

    /// 终端当前是否显示在界面上:任一终端标签是所在组的激活标签(在右栏时右栏必须可见)。
    var isTerminalShown: Bool {
        terminalTabs.contains { tab in host(of: tab.id).map { isTabShown(tab.id, in: $0) } ?? false }
    }

    /// 输出面板当前是否显示在界面上。
    var isOutputShown: Bool {
        guard let (host, tab) = existingTab(for: .preview(id: Self.outputTabID)) else { return false }
        return isTabShown(tab.id, in: host)
    }

    /// 标签是否正显示:所在组的激活标签,且(在右栏时)右栏可见。
    func isTabShown(_ id: UUID, in host: DockHost) -> Bool {
        guard let loc = dock(host).location(of: id), dock(host).group(loc.group)?.activeID == id else { return false }
        return host == .center || layout.rightVisible
    }

    /// 显示终端:当前项目已有终端标签时聚焦它;一个都没有时以标签放进右栏新开一个。
    func showTerminal() {
        let tab = openTab(.terminal(id: residentTerminalID), title: String(localized: "终端"), host: .right)
        activateAnyTab(tab)
    }

    /// 切到已有的终端标签(当前显示的优先,否则第一个),不新建。
    /// - Returns: 是否找到并切换了终端标签
    @discardableResult
    func focusExistingTerminal() -> Bool {
        let tabs = terminalTabs
        let shown = tabs.first { tab in host(of: tab.id).map { isTabShown(tab.id, in: $0) } ?? false }
        guard let target = shown ?? tabs.first else { return false }
        activateAnyTab(target.id)
        return true
    }

    /// 切到已有的浏览器标签(当前显示的优先,否则第一个符合条件的),不新建。
    /// - Parameter include: 按浏览器标签 id 过滤(如只取当前项目的浏览器)
    /// - Returns: 是否找到并切换了浏览器标签
    @discardableResult
    func focusExistingBrowser(where include: (String) -> Bool) -> Bool {
        let tabs = (rightDock.allTabs + dock.allTabs).filter { tab in
            guard case .preview(let id) = tab.kind, let browserID = Self.browserID(fromTab: id) else { return false }
            return include(browserID)
        }
        let shown = tabs.first { tab in host(of: tab.id).map { isTabShown(tab.id, in: $0) } ?? false }
        guard let target = shown ?? tabs.first else { return false }
        activateAnyTab(target.id)
        return true
    }

    /// 隐藏终端(关闭标签;终端进程由终端存储保留)。
    /// - Parameter root: 要关闭哪个项目的终端标签(默认当前项目)
    func hideTerminal(root: String? = nil) {
        let id = root.map { "bottom:" + $0 } ?? residentTerminalID
        if let (host, tab) = existingTab(for: .terminal(id: id)) {
            mutateDock(host) { $0.close(tab.id) }
            syncSelectionFromDock()
        }
    }

    /// 切换终端显隐(⌘J):正显示终端时收起——常驻终端关闭标签(进程由终端存储保留),
    /// 新建的终端(进程随标签存亡)只收起右栏;否则显示终端。
    func toggleTerminal() {
        guard isTerminalShown else { showTerminal(); return }
        let shown = terminalTabs.first { tab in host(of: tab.id).map { isTabShown(tab.id, in: $0) } ?? false }
        if let shown, case .terminal(let id) = shown.kind, !id.hasPrefix("bottom:"), host(of: shown.id) == .right {
            layout.rightVisible = false
        } else {
            hideTerminal()
        }
    }

    /// 显示输出面板(默认放进右栏)。
    func showOutput() {
        let tab = openTab(.preview(id: Self.outputTabID), title: String(localized: "输出"), host: .right)
        activateAnyTab(tab)
    }

    /// 隐藏输出面板(关闭标签)。
    func hideOutput() {
        for tab in outputTabs {
            if let host = host(of: tab.id) { mutateDock(host) { $0.close(tab.id) } }
        }
        syncSelectionFromDock()
    }

    /// 切换输出面板显隐。
    func toggleOutput() {
        if isOutputShown { hideOutput() } else { showOutput() }
    }
}
