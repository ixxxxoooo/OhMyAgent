// @author ixxxxoooo
// 悬浮信息卡片测试:声明按语言着色、下面的说明确实画出来(此前长声明折行会把说明挤出卡片,只剩声明和空白)。

import AppKit
import Testing
@testable import EditorKit

@MainActor
@Suite("悬浮信息卡片")
struct NativeInfoCardTests {
    private let markdown = "```swift\nstatic func withUsage(_ steps: [ScenarioStep], used: Int, cost: Double = 0.0421) -> [ScenarioStep]\n```\n\n在场景末尾补一次用量更新(让输入栏的上下文环有数据)。"
    private let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    @Test("围栏里的声明按语言着色,说明保持正文样式")
    func fenceIsHighlighted() {
        let text = NativeInfoCardView.render(markdown: markdown, monoFont: mono)
        #expect(text.string.contains("在场景末尾补一次用量更新"))
        var colors = Set<String>()
        text.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if let color = (value as? NSColor)?.usingColorSpace(.sRGB) { colors.insert("\(color.redComponent),\(color.greenComponent),\(color.blueComponent)") }
        }
        #expect(colors.count >= 4, "声明应有多种语法色,实际 \(colors.count) 种")
    }

    @Test("长声明折行后,说明仍画在卡片内(卡片最后一行有墨迹)")
    func docStaysInsideCard() throws {
        let card = NativeInfoCardView(frame: .zero)
        let size = card.setContent(NativeInfoCardView.render(markdown: markdown, monoFont: mono))
        card.frame = NSRect(origin: .zero, size: size)
        let rep = try #require(card.bitmapImageRepForCachingDisplay(in: card.bounds))
        card.cacheDisplay(in: card.bounds, to: rep)
        let scale = rep.pixelsWide / Int(size.width)
        var inkInLastLine = 0
        for y in Int(size.height) - 28..<Int(size.height) - 12 {
            for x in 12..<Int(size.width) - 12 {
                if let c = rep.colorAt(x: x * scale, y: y * scale)?.usingColorSpace(.sRGB), c.redComponent < 0.6 { inkInLastLine += 1 }
            }
        }
        #expect(inkInLastLine > 50, "卡片底部的说明行没有画出来")
    }

    @Test("签名帮助:当前参数加粗并换成强调色;范围越界时不崩溃")
    func signatureActiveParameter() {
        let label = "f(a: Int, b: String)"
        let range = (label as NSString).range(of: "b: String")
        let text = NativeInfoCardView.render(signature: label, activeParameter: range, monoFont: mono)
        #expect(text.string == label)
        let active = text.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor
        let normal = text.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        #expect(active != normal)
        let bad = NativeInfoCardView.render(signature: label, activeParameter: NSRange(location: 100, length: 5), monoFont: mono)
        #expect(bad.string == label)
    }
}
