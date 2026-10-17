// @author ixxxxoooo
// 终端 OSC 颜色查询/设置的补丁:SwiftTerm 1.5.1 把 OSC 11(背景色)与 OSC 12(光标色)的查询
// 当成「第二/第三个参数」处理,单参数的 `ESC ] 11 ; ? ESC \` 永远得不到回复,
// OpenCode、vim 等靠它判断深浅色的程序会超时并回退为深色。这里接管 11/12,补上正确回复。

import AppKit
import DesignSystem
import Foundation
import SwiftTerm

/// OSC 颜色序列的纯函数:格式化回复与解析颜色规格。
enum TerminalOSC {
    /// 生成 OSC 颜色回复(xterm 格式,16 位通道,以 ST 结尾)。
    /// - Parameters:
    ///   - code: OSC 编号(10 前景 / 11 背景 / 12 光标)
    ///   - color: 颜色
    /// - Returns: 完整的转义序列字符串
    static func reply(code: Int, color: NSColor) -> String {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        func channel(_ value: CGFloat) -> String {
            String(format: "%04x", Int((min(max(value, 0), 1) * 65535).rounded()))
        }
        return "\u{1b}]\(code);rgb:\(channel(rgb.redComponent))/\(channel(rgb.greenComponent))/\(channel(rgb.blueComponent))\u{1b}\\"
    }

    /// 解析颜色规格:`rgb:R/G/B`(每段 1~4 位十六进制)或 `#RRGGBB`。
    /// - Parameter spec: 规格文本
    /// - Returns: 颜色;无法解析返回 nil
    static func parse(_ spec: String) -> NSColor? {
        let text = spec.trimmingCharacters(in: .whitespaces)
        func scaled(_ hex: Substring) -> CGFloat? {
            guard (1...4).contains(hex.count), let value = UInt32(hex, radix: 16) else { return nil }
            let maxValue = CGFloat((1 << (4 * hex.count)) - 1)
            return CGFloat(value) / maxValue
        }
        if text.lowercased().hasPrefix("rgb:") {
            let parts = text.dropFirst(4).split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 3, let r = scaled(parts[0]), let g = scaled(parts[1]), let b = scaled(parts[2]) else { return nil }
            return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
        }
        if text.hasPrefix("#"), text.count == 7, let value = UInt32(text.dropFirst(), radix: 16) {
            return NSColor(srgbRed: CGFloat((value >> 16) & 0xff) / 255, green: CGFloat((value >> 8) & 0xff) / 255, blue: CGFloat(value & 0xff) / 255, alpha: 1)
        }
        return nil
    }

    /// 在 `TerminalView` 上接管 OSC 11/12:`?` 查询回复当前颜色,否则按规格设置。
    /// - Parameter view: 终端视图(颜色与回复通道都经由它)
    @MainActor
    static func install(on view: TerminalView) {
        let terminal = view.getTerminal()
        terminal.registerOscHandler(code: 11) { [weak view] data in
            MainActor.assumeIsolated {
                guard let view else { return }
                handle(data) { color in
                    if let color { view.nativeBackgroundColor = color; return nil }
                    return view.nativeBackgroundColor
                } reply: { terminal.sendResponse(text: reply(code: 11, color: $0)) }
            }
        }
        terminal.registerOscHandler(code: 12) { [weak view] data in
            MainActor.assumeIsolated {
                guard let view else { return }
                handle(data) { color in
                    if let color { view.caretColor = color; return nil }
                    return view.caretColor
                } reply: { terminal.sendResponse(text: reply(code: 12, color: $0)) }
            }
        }
    }

    /// 处理一条 OSC 数据:首个参数为 `?` 时查询,否则设置。
    /// - Parameters:
    ///   - data: OSC 编号之后的载荷
    ///   - access: 传入新颜色即设置(返回 nil);传 nil 则返回当前颜色
    ///   - reply: 发送查询回复
    @MainActor
    private static func handle(_ data: ArraySlice<UInt8>, access: (NSColor?) -> NSColor?, reply: (NSColor) -> Void) {
        let first = String(decoding: data, as: UTF8.self).split(separator: ";", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        if first == "?" {
            if let current = access(nil) { reply(current) }
        } else if let color = parse(first) {
            _ = access(color)
        }
    }
}
