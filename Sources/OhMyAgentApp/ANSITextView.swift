// @author ixxxxoooo
// ANSI 文本视图:把 ChatKit.ANSIParser 的样式片段渲染为 SwiftUI 富文本。

import ChatKit
import DesignSystem
import SwiftUI

/// 渲染含 ANSI 颜色的终端输出。
/// 正文由 AppKit 文本叶子(`OutputTextLeaf`)绘制:原生选择、流式只替换尾部;
/// 本类型保留 ANSI 调色板与 `attributed`(供测试与旧调用方复用)。
struct ANSITextView: View {
    let raw: String
    var fontSize: CGFloat = 12
    /// 最多渲染的末尾行数(默认沿用解析器上限 400)
    var maxLines = 400
    /// 默认文字色(ANSI 显式着色的片段不受影响)
    var tint: Color = OMColors.primaryText

    var body: some View {
        OutputTextLeaf(raw: raw, fontSize: fontSize, maxLines: maxLines, ansi: true, tint: tint)
    }

    /// 构造富文本(静态方法便于测试)。
    /// - Parameters:
    ///   - raw: 原始输出
    ///   - fontSize: 字号
    ///   - maxLines: 只保留末尾的行数
    static func attributed(_ raw: String, fontSize: CGFloat, maxLines: Int = 400) -> AttributedString {
        var result = AttributedString()
        for span in ANSIParser.parse(raw, maxLines: maxLines) {
            var piece = AttributedString(span.text)
            piece.font = OMFonts.custom(fontSize, weight: span.bold ? .semibold : .regular, design: .monospaced) // ui-lint:allow 终端 ANSI 加粗属于输出内容
            if let color = span.foreground { piece.foregroundColor = Self.color(color, dim: span.dim) }
            else if span.dim { piece.foregroundColor = OMColors.secondaryText }
            if span.underline { piece.underlineStyle = .single }
            result.append(piece)
        }
        return result
    }

    /// ANSI 调色板:取自当前主题(`OMTerminalPalette`),0/7/8/15 号映射到界面前景梯度以保证在内容区上可读。
    static func color(_ color: ANSIColor, dim: Bool) -> Color {
        let base: Color
        switch color {
        case .basic(let index): base = basic(index)
        case .palette(let index): base = palette(index)
        case .rgb(let r, let g, let b): base = ThemeRGB(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255).color
        }
        return dim ? base.opacity(0.6) : base
    }

    private static func basic(_ index: Int) -> Color {
        switch index {
        case 0: return OMColors.secondaryText
        case 7, 15: return OMColors.primaryText
        case 8: return OMColors.tertiaryText
        case 1...6, 9...14:
            return Color(nsColor: OMTerminalPalette.ansi(dark: OMTerminalPalette.currentIsDark)[index])
        default: return OMColors.primaryText
        }
    }

    private static func palette(_ index: Int) -> Color {
        switch index {
        case 0..<16: return basic(index)
        case 16..<232:
            let n = index - 16
            func level(_ v: Int) -> Double { v == 0 ? 0 : Double(55 + 40 * v) / 255 }
            return ThemeRGB(red: level(n / 36), green: level((n / 6) % 6), blue: level(n % 6)).color
        default:
            let gray = Double(8 + 10 * (index - 232)) / 255
            return ThemeRGB(red: gray, green: gray, blue: gray).color
        }
    }
}

/// ANSI 渲染的单项缓存(引用类型,放在 `@State` 里跨 body 保留)。
/// 主题切换会让 `ThemeRuntime.generation` 变化,据此失效。
@MainActor
final class ANSIRenderCache {
    private var key: (raw: String, fontSize: CGFloat, maxLines: Int, generation: Int)?
    private var value = AttributedString()
    /// 实际构造次数(测试用)
    private(set) var buildCount = 0

    /// 取富文本:参数与上次一致则复用。
    func attributed(_ raw: String, fontSize: CGFloat, maxLines: Int) -> AttributedString {
        let generation = ThemeRuntime.generation
        if let key, key.raw == raw, key.fontSize == fontSize, key.maxLines == maxLines, key.generation == generation { return value }
        value = ANSITextView.attributed(raw, fontSize: fontSize, maxLines: maxLines)
        key = (raw, fontSize, maxLines, generation)
        buildCount += 1
        return value
    }
}
