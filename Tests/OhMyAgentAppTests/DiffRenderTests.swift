// @author ixxxxoooo
// 统一 Diff 渲染回归:新增行的行号槽有独立底色,行与行之间没有接缝(截图里「绿色边缘怪异」的问题)。

import AppKit
import DiffKit
import SwiftUI
import Testing

@testable import OhMyAgentApp

@MainActor
@Suite("统一 Diff 渲染")
struct DiffRenderTests {
    /// 渲染一个全新增文件的统一 Diff,返回位图。
    private func render() throws -> NSBitmapImageRep {
        let diff = LineDiff.diff(old: nil, new: "a\nb\nc\nd\ne\n")
        let view = DiffView(diff: diff)
            .frame(width: 520)
            .background(Color.white)
        // Diff 已改为 AppKit 文本叶子,ImageRenderer 只会画出占位禁止图标,须经真实的 NSHostingView 离屏绘制
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 520, height: 10)
        let height = max(host.fittingSize.height, 120)
        host.frame = NSRect(x: 0, y: 0, width: 520, height: height)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let bounds = host.bounds
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: bounds))
        host.cacheDisplay(in: bounds, to: rep)
        if let path = ProcessInfo.processInfo.environment["DIFF_DUMP"], let png = rep.representation(using: .png, properties: [:]) {
            try png.write(to: URL(fileURLWithPath: path))
        }
        return rep
    }

    private func rgb(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> [Int] {
        guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return [] }
        return [Int(color.redComponent * 255), Int(color.greenComponent * 255), Int(color.blueComponent * 255)]
    }

    @Test("行号槽比正文深一档且纵向连续")
    func gutterIsDistinctAndContinuous() throws {
        let rep = try render()
        // 取正文区一列、行号槽区一列,沿纵向扫描(跳过头部与边框)
        let bodyX = 300 * 2
        let gutterX = 30 * 2
        var bodyColors = Set<[Int]>()
        var gutterColors = Set<[Int]>()
        for y in stride(from: 80, to: rep.pixelsHigh - 44, by: 1) {
            bodyColors.insert(rgb(rep, bodyX, y))
            gutterColors.insert(rgb(rep, gutterX, y))
        }
        // 正文区只有一种底色(没有行间接缝),行号槽区也只有一种底色(文字像素极少落在该列)
        #expect(bodyColors.count == 1)
        #expect(gutterColors.count <= 2)
        #expect(bodyColors != gutterColors)
    }

    @Test("新增行不带半透明叠加:正文底色为不透明")
    func backgroundIsOpaque() throws {
        let rep = try render()
        let color = try #require(rep.colorAt(x: 300 * 2, y: 90)?.usingColorSpace(.sRGB))
        #expect(color.alphaComponent == 1)
    }
}
