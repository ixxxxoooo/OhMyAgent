// @author ixxxxoooo
// 右侧栏里的内置浏览器:默认在右侧栏打开,可移到编辑区标签,也可关闭。无视图。

import Foundation

@MainActor
public extension WorkbenchModel {
    /// 在右侧栏显示浏览器(右侧栏随之展开并切到浏览器)。
    /// - Parameter id: 浏览器标签 id
    func showSidebarBrowser(id: String) {
        layout.sidebarBrowserID = id
        layout.sidebarBrowserActive = true
        layout.activeToolsChat = nil
        layout.rightVisible = true
    }

    /// 把右侧栏里的浏览器移到编辑区(会话右侧分屏)。
    /// - Parameter title: 编辑区标签标题
    func moveSidebarBrowserToEditor(title: String) {
        guard let id = layout.sidebarBrowserID else { return }
        closeSidebarBrowserSlot()
        let tab = dock.openBeside(.preview(id: Self.browserTabPrefix + id), title: title, of: dock.focusedGroupID, preview: false, keepFocus: true)
        dock.activate(tab)
        syncSelectionFromDock()
        scheduleSave()
    }

    /// 清掉右侧栏的浏览器占位(网页模型由浏览器控制器按上限回收)。
    func closeSidebarBrowserSlot() {
        layout.sidebarBrowserID = nil
        layout.sidebarBrowserActive = false
    }
}
