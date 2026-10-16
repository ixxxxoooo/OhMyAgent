// @author ygw
// 标签可见性:保活的标签在后台保持挂载,这里提供「是否可见」环境值与 AppKit 视图同步工具。

import AppKit
import SwiftUI

private struct TabIsActiveKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// 标签内容当前是否可见:不可见时应暂停轮询等后台工作,AppKit 视图应隐藏并让出键盘焦点。
    public var tabIsActive: Bool {
        get { self[TabIsActiveKey.self] }
        set { self[TabIsActiveKey.self] = newValue }
    }
}

extension NSView {
    /// 按标签可见性同步:隐藏时若键盘焦点在本视图内则让出,避免在看不见的视图里继续输入。
    /// - Parameter active: 标签是否可见
    @MainActor
    public func syncTabActive(_ active: Bool) {
        let hidden = !active
        guard isHidden != hidden else { return }
        if hidden, let window, let responder = window.firstResponder as? NSView, responder === self || responder.isDescendant(of: self) {
            window.makeFirstResponder(nil)
        }
        isHidden = hidden
    }
}
