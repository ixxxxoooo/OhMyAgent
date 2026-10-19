// @author ixxxxoooo
// 只读 Agent 终端:把 `TerminalSession` 的输出逐段喂给 SwiftTerm 渲染(颜色、光标控制、回滚、选择复制),
// 键盘输入一律丢弃。输出被截断或整段替换时整屏重绘。

import AppKit
import ChatKit
import DesignSystem
import IconKit
import SwiftTerm
import SwiftUI

/// 把输出文本转成终端字节:裸 `\n` 补成 `\r\n`(管道输出没有 pty 的换行转换,不补会阶梯式错位)。
enum AgentTerminalFeed {
    /// - Parameters:
    ///   - bytes: UTF-8 字节
    ///   - previousWasCR: 上一段是否以 `\r` 结尾(`\r` 与 `\n` 被拆在两段时不重复补)
    /// - Returns: 可直接 `feed` 的字节
    static func crlf(_ bytes: ArraySlice<UInt8>, previousWasCR: inout Bool) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count + bytes.count / 16)
        for byte in bytes {
            if byte == 0x0A, !previousWasCR { out.append(0x0D) }
            out.append(byte)
            previousWasCR = byte == 0x0D
        }
        return out
    }
}

/// 通知观察者的令牌:释放时自动注销,避免观察者残留在通知中心。
private final class NotificationToken: @unchecked Sendable {
    private let token: NSObjectProtocol
    init(_ token: NSObjectProtocol) { self.token = token }
    deinit { NotificationCenter.default.removeObserver(token) }
}

/// 持有 SwiftTerm 视图并负责把会话输出镜像进去。
@MainActor
final class AgentTerminalScreen: NSObject, TerminalViewDelegate {
    let view: TerminalView
    private var fedBytes = 0
    private var fedDiscontinuity = 0
    private var previousWasCR = false
    private var themeToken: NotificationToken?

    override init() {
        view = OMTerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 360))
        super.init()
        view.terminalDelegate = self
        view.getTerminal().options.scrollback = 5000
        view.font = TerminalPrefs.load().font
        TerminalController.applyTheme(to: view)
        themeToken = NotificationToken(NotificationCenter.default.addObserver(forName: ThemeRuntime.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self { TerminalController.applyTheme(to: self.view) } }
        })
    }

    /// 同步会话输出:延伸则只喂新增部分,否则重置后整屏重绘。
    func sync(_ session: TerminalSession) {
        let text = session.output
        let total = text.utf8.count
        if session.discontinuity != fedDiscontinuity || total < fedBytes {
            view.getTerminal().resetToInitialState()
            fedBytes = 0
            previousWasCR = false
            fedDiscontinuity = session.discontinuity
        }
        guard total > fedBytes else { return }
        let slice = Array(text.utf8.dropFirst(fedBytes))
        fedBytes = total
        view.feed(byteArray: AgentTerminalFeed.crlf(slice[...], previousWasCR: &previousWasCR)[...])
    }

    // MARK: TerminalViewDelegate(只读:丢弃全部输入)

    nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    nonisolated func setTerminalTitle(source: TerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {}
    nonisolated func scrolled(source: TerminalView, position: Double) {}
    nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    nonisolated func clipboardCopy(source: TerminalView, content: Data) {
        guard let text = String(data: content, encoding: .utf8) else { return }
        MainActor.assumeIsolated {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }
}

/// 把 `AgentTerminalScreen` 嵌入 SwiftUI;输出变化时(`revision` 变化)同步。
private struct AgentTerminalHost: NSViewRepresentable {
    let session: TerminalSession
    /// 仅用于让 SwiftUI 在输出变化时调用 `updateNSView`
    let revision: Int

    func makeCoordinator() -> AgentTerminalScreen { AgentTerminalScreen() }

    func makeNSView(context: Context) -> TerminalView {
        context.coordinator.sync(session)
        return context.coordinator.view
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {
        context.coordinator.sync(session)
    }
}

/// 终端面板里的 Agent 终端内容:只读提示条 + 终端。
struct AgentTerminalContentView: View {
    let session: TerminalSession

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                Image.om("lock", size: 12).foregroundStyle(OMColors.tertiaryText)
                    .omTooltip("Agent 正在使用这个终端,只读")
                    .frame(height: 16)
                ShellCommandText(command: session.command, lineLimit: 6)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if session.isBackground { OMTag(String(localized: "后台"), tint: OMColors.secondaryText) }
                if session.isRunning {
                    OMSpinner(.mini)
                } else if let code = session.exitCode {
                    OMTag(code == 0 ? String(localized: "退出 0") : String(localized: "退出 \(code)"), tint: code == 0 ? OMColors.success : OMColors.danger)
                } else if let signal = session.signal {
                    OMTag(signal, tint: OMColors.danger)
                } else {
                    OMTag(String(localized: "已结束"), tint: OMColors.secondaryText)
                }
            }
            .font(OMFonts.monoSmall)
            .foregroundStyle(OMColors.secondaryText)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(minHeight: 28)
            .background(OMColors.surface)
            Divider()
            AgentTerminalHost(session: session, revision: session.output.utf8.count &+ session.discontinuity &* 1_000_003)
                .clipped()  // 实时缩放期间终端保持原尺寸,由这里裁剪(见 LiveResizeGate)
                .padding(.leading, 6)
                .background(Color(nsColor: OMTerminalPalette.background))
                .overlay(alignment: .topLeading) {
                    if session.awaitsBufferedOutput {
                        Text("命令运行中,结束后才会返回输出")
                            .font(OMFonts.caption)
                            .foregroundStyle(OMColors.tertiaryText)
                            .padding(.leading, 12).padding(.top, 20)
                    }
                }
        }
        .accessibilityLabel("Agent 终端")
    }
}
