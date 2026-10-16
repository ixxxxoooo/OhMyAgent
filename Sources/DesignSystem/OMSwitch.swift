// @author ixxxxoooo
// 统一开关:卡片行(扩展、MCP、模型提供商、Agent 注册表)里的启用开关一律用它,
// 固定 `.small` 尺寸并隐藏标签,避免同类页面出现大小不一的开关。标签只用于无障碍。

import SwiftUI

/// 统一尺寸的开关(无可见标签)。
public struct OMSwitch: View {
    private let accessibilityName: String
    private let isOn: Binding<Bool>

    /// - Parameters:
    ///   - accessibilityName: 无障碍标签(例如「启用 github」)
    ///   - isOn: 开关状态
    public init(_ accessibilityName: String, isOn: Binding<Bool>) {
        self.accessibilityName = accessibilityName
        self.isOn = isOn
    }

    public var body: some View {
        Toggle(isOn: isOn) { Text(verbatim: accessibilityName) }
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
            .accessibilityLabel(accessibilityName)
    }
}
