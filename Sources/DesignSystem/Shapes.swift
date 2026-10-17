// @author ixxxxoooo
// 形状令牌:标签/徽标/分段控件/芯片的统一外形。
// 纸感规范禁止胶囊(AGENTS.md 4.4):主题提供语义圆角集合时取 `OMRadius.tag`,其他主题保持胶囊外观。

import SwiftUI

/// 标签/徽标/分段控件/芯片的统一形状:旧主题为胶囊,纸感主题为 `OMRadius.tag` 的圆角矩形。
/// 进度条、滑块轨道、开关等「功能性」细长形状仍直接用 `Capsule()`。
public struct OMPillShape: InsettableShape {
    /// 构造时取圆角(在视图 `body` 内构造,因此会随主题刷新);nil 表示胶囊。
    private let corner: CGFloat?
    private var insetAmount: CGFloat = 0

    public init() {
        corner = ThemeRuntime.style.radiusSet == nil ? nil : OMRadius.tag
    }

    public func path(in rect: CGRect) -> Path {
        let area = rect.insetBy(dx: insetAmount, dy: insetAmount)
        let limit = min(area.width, area.height) / 2
        let radius = corner.map { min($0, limit) } ?? limit
        return Path(roundedRect: area, cornerRadius: radius, style: .continuous)
    }

    public func inset(by amount: CGFloat) -> OMPillShape {
        var copy = self
        copy.insetAmount += amount
        return copy
    }
}
