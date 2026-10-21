// @author ixxxxoooo
// IDE 窗口的文件宿主:复用 Agent 窗口的 `FileTabView` 时,通过环境值把脏标记、跳转与项目根改接到 IDE 窗口。

import SwiftUI

/// IDE 文件宿主(值类型,闭包均在主线程调用)。
struct IDEFileHost {
    /// 工作区根目录
    var root: String?
    /// 打开文件(路径,行号,是否预览)
    var open: @MainActor (String, Int?, Bool) -> Void
    /// 同步脏标记(是否脏,路径)
    var setDirty: @MainActor (Bool, String) -> Void
}

extension EnvironmentValues {
    /// 当前视图子树所在的 IDE 窗口宿主;Agent 窗口里为 nil。
    @Entry var ideFileHost: IDEFileHost?
}
