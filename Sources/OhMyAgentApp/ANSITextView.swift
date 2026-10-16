// @author ixxxxoooo
// ANSI 文本视图:把 ChatKit.ANSIParser 的样式片段渲染为 SwiftUI 富文本。

import ChatKit
import DesignSystem
import SwiftUI

/// 渲染含 ANSI 颜色的终端输出。
struct ANSITextView: View {
    let raw: String
    var fontSize: CGFloat = 11.5

    var body: some View {
        Text(Self.attributed(raw, fontSize: fontSize))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 构造富文本(静态方法便于测试)。
    static func attributed(_ raw: String, fontSize: CGFloat) -> AttributedString {
        var result = AttributedString()
        for span in ANSIParser.parse(raw) {
            var piece = AttributedString(span.text)
            piece.font = .system(size: fontSize, weight: span.bold ? .semibold : .regular, design: .monospaced)
            if let color = span.foreground { piece.foregroundColor = Self.color(color, dim: span.dim) }
            else if span.dim { piece.foregroundColor = OMColors.secondaryText }
            if span.underline { piece.underlineStyle = .single }
            result.append(piece)
        }
        return result
    }

    /// 标准 xterm 调色板,在浅色/深色背景上都保持可读。
    static func color(_ color: ANSIColor, dim: Bool) -> Color {
        let base: Color
        switch color {
        case .basic(let index): base = basic(index)
        case .palette(let index): base = palette(index)
        case .rgb(let r, let g, let b): base = Color(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
        }
        return dim ? base.opacity(0.6) : base
    }

    private static func basic(_ index: Int) -> Color {
        switch index {
        case 0: return Color(nsColor: .secondaryLabelColor)
        case 1: return Color(nsColor: .systemRed)
        case 2: return Color(nsColor: .systemGreen)
        case 3: return Color(nsColor: .systemOrange)
        case 4: return Color(nsColor: .systemBlue)
        case 5: return Color(nsColor: .systemPurple)
        case 6: return Color(nsColor: .systemTeal)
        case 7: return Color(nsColor: .labelColor)
        case 8: return Color(nsColor: .tertiaryLabelColor)
        case 9: return Color(nsColor: .systemRed)
        case 10: return Color(nsColor: .systemGreen)
        case 11: return Color(nsColor: .systemYellow)
        case 12: return Color(nsColor: .systemBlue)
        case 13: return Color(nsColor: .systemPink)
        case 14: return Color(nsColor: .systemCyan)
        default: return Color(nsColor: .labelColor)
        }
    }

    private static func palette(_ index: Int) -> Color {
        switch index {
        case 0..<16: return basic(index)
        case 16..<232:
            let n = index - 16
            func level(_ v: Int) -> Double { v == 0 ? 0 : Double(55 + 40 * v) / 255 }
            return Color(red: level(n / 36), green: level((n / 6) % 6), blue: level(n % 6))
        default:
            let gray = Double(8 + 10 * (index - 232)) / 255
            return Color(white: min(max(gray, 0), 1))
        }
    }
}
