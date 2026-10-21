// @author ixxxxoooo
// IDE 窗口的文件宿主:复用 Agent 窗口的 `FileTabView` 时,通过环境值把脏标记、跳转与项目根改接到 IDE 窗口。

import EditorKit
import SwiftUI

/// IDE 文件宿主(值类型,闭包均在主线程调用)。
struct IDEFileHost {
    /// 工作区根目录
    var root: String?
    /// 打开文件(路径,行号,是否预览)
    var open: @MainActor (String, Int?, Bool) -> Void
    /// 同步脏标记(是否脏,路径)
    var setDirty: @MainActor (Bool, String) -> Void
    /// 把引用标记(`@路径:行`)加入 Agent 面板输入框
    var reference: @MainActor (String) -> Void
    /// 上报某文件当前的诊断(参数:路径、诊断、对应文本;空数组表示清除)
    var report: @MainActor (String, [EditorDiagnostic], String) -> Void
    /// 上报某文件的光标状态(路径,光标)
    var caret: @MainActor (String, EditorCaret) -> Void
}

extension EnvironmentValues {
    /// 当前视图子树所在的 IDE 窗口宿主;Agent 窗口里为 nil。
    @Entry var ideFileHost: IDEFileHost?
}
