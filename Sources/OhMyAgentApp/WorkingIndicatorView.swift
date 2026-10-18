// @author ixxxxoooo
// 会话流末尾的等待指示:参考 Claude Code 的「✻ 思考中… (12s · 按 Esc 中断)」。
// 轮次运行期间始终显示;等待用户批准/回答时改为静态提示,不再转动。

import ChatKit
import DesignSystem
import SwiftUI

/// 运行中的等待指示行。
struct WorkingIndicatorView: View {
    let model: SessionModel
    /// 外观里选择的等待动词风格(变化时自动刷新)
    @AppStorage(ClientPrefs.Key.workingVerbStyle) private var verbStyleRaw = WorkingVerbStyle.classic.rawValue

    var body: some View {
        if model.isRunning, let start = model.turnStartedAt {
            let style = WorkingVerbStyle.resolve(verbStyleRaw)
            let waitingForUser = !model.pendingPermissions.isEmpty || !model.pendingElicitations.isEmpty
            // 每秒只刷新耗时文字;字符帧动画由 Core Animation 驱动(OMGlyphCycle),不再每 0.15 秒重算视图
            ActiveTimeline(interval: 1, start: start) { date in
                let seconds = Int(date.timeIntervalSince(start))
                HStack(spacing: 8) {
                    OMGlyphCycle(
                        frames: style.glyphFrames, resting: style.restingGlyph, font: OMFonts.body.weight(.medium),
                        color: waitingForUser ? OMColors.tertiaryText : OMColors.accent, animated: !waitingForUser
                    )
                    Text(label(seconds: seconds, start: start, waitingForUser: waitingForUser, style: style))
                        .font(OMFonts.small)
                        .foregroundStyle(OMColors.secondaryText)
                        .monospacedDigit()
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 2)
                .accessibilityElement(children: .combine)
            }
        }
    }

    /// 文案:等待用户时提示「等待你的确认」,否则为「动词… (耗时 · 中断提示)」。
    private func label(seconds: Int, start: Date, waitingForUser: Bool, style: WorkingVerbStyle) -> String {
        if waitingForUser {
            return "\(String(localized: "等待你的回复"))… (\(WorkingStatus.elapsed(seconds)))"
        }
        // 父会话在等前台子代理:显示「等待子代理」,与 Cursor 一致
        let waiting = model.timeline.runningForegroundSubagentCount()
        if waiting > 0 {
            let verb = waiting == 1 ? String(localized: "等待子代理") : String(localized: "等待 \(waiting) 个子代理")
            return WorkingStatus.line(verb: verb, seconds: seconds, canInterrupt: true)
        }
        let verb = WorkingStatus.verb(seed: Int(start.timeIntervalSince1970), style: style)
        return WorkingStatus.line(verb: verb, seconds: seconds, canInterrupt: true)
    }
}
