// @author ixxxxoooo
// 侧栏底部的更新按钮:检测到新版本时显示「更新」,下载中显示进度,下载完成同样显示「更新」(点击即重启安装)。

import ChatKit
import DesignSystem
import SwiftUI

/// 侧栏底部更新按钮;没有可用更新时不占位。
struct UpdateFooterButton: View {
    @State private var updates = UpdateModel.shared

    var body: some View {
        if let spec = Self.spec(phase: updates.phase, available: updates.availableInfo) {
            Button { updates.performPrimaryAction() } label: {
                HStack(spacing: 4) {
                    if spec.busy { OMSpinner(.small) }
                    Text(spec.title)
                }
                .font(OMFonts.caption.weight(.medium))
                .foregroundStyle(OMColors.onAccent)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(OMColors.accent, in: OMPillShape())
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(spec.busy)
            .omTooltip(spec.help)
            .accessibilityLabel(spec.title)
        }
    }

    /// 按钮外观描述。
    struct Spec: Equatable { var title: String; var icon: String; var help: String; var busy: Bool }

    /// 根据更新阶段决定按钮内容;无更新返回 nil。
    /// - Parameters:
    ///   - phase: 下载/安装阶段
    ///   - available: 已发现的新版本
    /// - Returns: 按钮描述
    static func spec(phase: UpdateModel.Phase, available: UpdateInfo?) -> Spec? {
        switch phase {
        case .ready(let staged):
            return Spec(title: String(localized: "更新"), icon: "refresh-cw", help: String(localized: "新版本 \(staged.version) 已下载,点击重启并完成更新"), busy: false)
        case .downloading(let value):
            return Spec(title: "\(Int(value * 100))%", icon: "download", help: String(localized: "正在下载新版本…"), busy: true)
        case .none, .failed:
            guard let info = available else { return nil }
            return Spec(title: String(localized: "更新"), icon: "download", help: String(localized: "发现新版本 \(info.version),点击下载并更新"), busy: false)
        }
    }
}
