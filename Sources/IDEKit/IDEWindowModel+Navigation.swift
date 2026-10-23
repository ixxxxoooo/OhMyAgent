// @author ixxxxoooo
// IDE 窗口的文件导航历史(标题栏「回退 / 前进」,对齐 VS Code 的 Go Back / Go Forward):
// 按文件路径记录(预览标签会被复用,按标签 ID 记录会丢历史),目标标签已关闭时重新打开。

import Foundation
import WorkbenchKit

public extension IDEWindowModel {
    /// 可以回退。
    var canGoBack: Bool { fileNav.canGoBack }
    /// 可以前进。
    var canGoForward: Bool { fileNav.canGoForward }

    /// 记录当前激活的文件(与当前记录相同则忽略);编辑器布局变化时由模型自动调用。
    func recordFileNavigation() {
        guard let path = activeFilePath else { return }
        fileNav.push(path)
    }

    /// 回退到上一个访问过的文件。
    func goBack() {
        guard let path = fileNav.back() else { return }
        openFile(path)
    }

    /// 前进到下一个访问过的文件。
    func goForward() {
        guard let path = fileNav.forward() else { return }
        openFile(path)
    }

    /// 从导航历史中移除某文件或目录之下的记录(删除、重命名、移动后)。
    /// - Parameter path: 文件或目录路径(空串忽略)
    func forgetNavigation(under path: String) {
        guard !path.isEmpty else { return }
        fileNav.remove { $0 == path || $0.hasPrefix(path + "/") }
    }
}
