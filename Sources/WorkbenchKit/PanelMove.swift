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

    /// 全部常驻终端标签(两个停靠区,每个项目最多一个)。
    var residentTerminalTabs: [WorkbenchTab] {
        allDockTabs.filter { if case .terminal(let id) = $0.kind { return id.hasPrefix("bottom:") } else { return false } }
    }

    /// 当前项目的常驻终端标签。
    var currentResidentTerminalTab: WorkbenchTab? {
        existingTab(for: .terminal(id: residentTerminalID))?.tab
    }

    /// 输出标签。
    var outputTabs: [WorkbenchTab] {
        allDockTabs.filter { $0.kind == .preview(id: Self.outputTabID) }
    }

    /// 终端当前是否显示在界面上:标签存在且是所在组的激活标签(在右栏时右栏必须可见)。
    var isTerminalShown: Bool {
        guard let (host, tab) = existingTab(for: .terminal(id: residentTerminalID)) else { return false }
        return isTabShown(tab.id, in: host)
    }

    /// 输出面板当前是否显示在界面上。
    var isOutputShown: Bool {
        guard let (host, tab) = existingTab(for: .preview(id: Self.outputTabID)) else { return false }
        return isTabShown(tab.id, in: host)
    }

    /// 标签是否正显示:所在组的激活标签,且(在右栏时)右栏可见。
    private func isTabShown(_ id: UUID, in host: DockHost) -> Bool {
        guard let loc = dock(host).location(of: id), dock(host).group(loc.group)?.activeID == id else { return false }
        return host == .center || layout.rightVisible
    }

    /// 显示终端:默认以标签放进右栏;已在某个停靠区时就地聚焦。
    func showTerminal() {
        let tab = openTab(.terminal(id: residentTerminalID), title: String(localized: "终端"), host: .right)
        activateAnyTab(tab)
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

    /// 切换终端显隐(⌘J)。
    func toggleTerminal() {
        if isTerminalShown { hideTerminal() } else { showTerminal() }
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
