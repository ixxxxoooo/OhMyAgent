// @author ixxxxoooo
// 输入区上方的状态卡片:`/goal` 目标条(排队/子 Agent/终端任务坞见 `ComposerDockView.swift`)。

import ACPKit
import ChatKit
import DesignSystem
import IconKit
import SwiftUI
import WorkbenchKit

/// `/goal` 目标条:显示当前目标与状态,可清除。
struct GoalChip: View {
    let model: SessionModel

    var body: some View {
        if let goal = model.goal {
            HStack(spacing: 8) {
                Image.om("target", size: 12)
                    .foregroundStyle(goal.isActive ? OMColors.accent : OMColors.secondaryText)
                Text(goal.objective)
                    .font(OMFonts.small)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(goal.isActive ? String(localized: "进行中") : String(localized: "已结束"))
                    .font(OMFonts.caption)
                    .foregroundStyle(OMColors.secondaryText)
                    .padding(.horizontal, 5)
                    .background(Capsule().fill(OMColors.pressedFill))
                Spacer(minLength: 4)
                Button { model.clearGoal() } label: {
                    Image.om("x", size: 11).foregroundStyle(OMColors.secondaryText)
                }
                .buttonStyle(.plain)
                .help("清除目标")
                .accessibilityLabel("清除目标")
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            .omGlassCard(cornerRadius: 15)
            .help(goal.objective)
        }
    }
}
