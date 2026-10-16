// @author ygw
// 会话流末尾的等待指示:参考 Claude Code 的「✻ 思考中… (12s · 按 Esc 中断)」。
// 轮次运行期间始终显示;等待用户批准/回答时改为静态提示,不再转动。

import ChatKit
import DesignSystem
import SwiftUI

/// 运行中的等待指示行。
struct WorkingIndicatorView: View {
    let model: SessionModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if model.isRunning, let start = model.turnStartedAt {
            let waitingForUser = !model.pendingPermissions.isEmpty || !model.pendingElicitations.isEmpty
            TimelineView(.periodic(from: start, by: reduceMotion || waitingForUser ? 1 : 0.15)) { context in
                let seconds = Int(context.date.timeIntervalSince(start))
                let tick = Int(context.date.timeIntervalSinceReferenceDate / 0.15)
                HStack(spacing: 8) {
                    Text(waitingForUser || reduceMotion ? "✻" : WorkingStatus.glyph(tick: tick))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(waitingForUser ? OMColors.tertiaryText : OMColors.accent)
                        .frame(width: 16)
                    Text(label(seconds: seconds, start: start, waitingForUser: waitingForUser))
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
    private func label(seconds: Int, start: Date, waitingForUser: Bool) -> String {
        if waitingForUser {
            return "\(String(localized: "等待你的回复"))… (\(WorkingStatus.elapsed(seconds)))"
        }
        let verb = WorkingStatus.verb(seed: Int(start.timeIntervalSince1970))
        return WorkingStatus.line(verb: verb, seconds: seconds, canInterrupt: true)
    }
}
