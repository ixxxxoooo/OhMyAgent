// @author ixxxxoooo
// IconKit:SVG path 解析(含圆弧)、Lucide 数据完整性、语义名映射、渲染非空、源码中不再残留 SF Symbol。

import AppKit
import Foundation
import SwiftUI
import Testing

@testable import IconKit

@Suite("SVG path 解析")
struct SVGPathParserTests {
    private func bounds(_ d: String) throws -> CGRect { try SVGPathParser.parse(d).boundingRect }

    @Test("绝对与相对命令、H/V、Z")
    func linesAndClose() throws {
        let rect = try bounds("M2 3H10V7h-8z")
        #expect(rect == CGRect(x: 2, y: 3, width: 8, height: 4))
        let relative = try bounds("m2 3 h8 v4 h-8 z")
        #expect(relative == rect)
    }

    @Test("紧凑数字写法:1.5-2.9、.5.5、指数")
    func compactNumbers() throws {
        let rect = try bounds("M0 0l1.5-2.9.5.5")
        #expect(abs(rect.minY - -2.9) < 1e-5)
        #expect(abs(rect.maxX - 2.0) < 1e-5)
        #expect(try bounds("M1e1 2E0L1e1 5").width == 0)
    }

    @Test("隐式 lineto:M 后跟多组坐标")
    func implicitLineTo() throws {
        let rect = try bounds("M0 0 10 0 10 10")
        #expect(rect == CGRect(x: 0, y: 0, width: 10, height: 10))
    }

    @Test("三次/二次贝塞尔及其平滑简写")
    func curves() throws {
        let cubic = try SVGPathParser.parse("M0 0C0 10 10 10 10 0S20-10 20 0")
        #expect(cubic.boundingRect.maxX == 20)
        let quad = try SVGPathParser.parse("M0 0Q5 10 10 0T20 0")
        #expect(quad.boundingRect.maxX == 20)
    }

    @Test("圆弧:半圆的包围盒与端点")
    func arcSemicircle() throws {
        // 从 (0,0) 到 (10,0),半径 5,上半圆(sweep=0 在 y 向下坐标系中朝 y 负方向)
        let path = try SVGPathParser.parse("M0 0A5 5 0 0 0 10 0")
        let rect = path.boundingRect
        #expect(abs(rect.minX) < 1e-6 && abs(rect.maxX - 10) < 1e-6)
        #expect(abs(abs(rect.height) - 5) < 0.05)
        #expect(abs((path.currentPoint?.x ?? -1) - 10) < 1e-9)
    }

    @Test("圆弧:整圆由两段半圆组成,包围盒为直径")
    func arcFullCircle() throws {
        let rect = try bounds("M5 12a7 7 0 1 0 14 0a7 7 0 1 0-14 0Z")
        #expect(abs(rect.width - 14) < 0.05 && abs(rect.height - 14) < 0.05)
        #expect(abs(rect.midX - 12) < 0.05 && abs(rect.midY - 12) < 0.05)
    }

    @Test("圆弧:半径过小自动放大,标志位可紧凑书写")
    func arcScaleAndFlags() throws {
        let scaled = try bounds("M0 0A1 1 0 0 1 10 0")
        #expect(abs(scaled.width - 10) < 1e-6)
        let compact = try bounds("M0 0a5 5 0 0110 0")
        #expect(abs(compact.width - 10) < 1e-6)
    }

    @Test("非法输入返回明确错误")
    func errors() {
        #expect(throws: SVGPathError.missingMoveTo) { try SVGPathParser.parse("L1 1") }
        #expect(throws: SVGPathError.missingNumber(command: "L")) { try SVGPathParser.parse("M0 0L1") }
        #expect(throws: SVGPathError.invalidFlag) { try SVGPathParser.parse("M0 0A5 5 0 2 0 10 0") }
        #expect(throws: SVGPathError.unexpectedCharacter("X")) { try SVGPathParser.parse("M0 0X1 1") }
        #expect(throws: SVGPathError.self) { try SVGPathParser.parse("5 5") }
    }
}

@Suite("Lucide 图标数据")
struct LucideDataTests {
    @Test("全部打包图标可解析,且落在 24×24 视口内")
    func allIconsParse() throws {
        #expect(IconCatalog.bundledNames.count >= 100)
        for name in IconCatalog.bundledNames.sorted() {
            let path = try #require(OMIconRenderer.path(lucideName: name), "解析失败:\(name)")
            let rect = path.boundingRect
            #expect(!rect.isEmpty || rect.width > 0 || rect.height > 0, "空图标:\(name)")
            #expect(rect.minX >= -0.5 && rect.minY >= -0.5 && rect.maxX <= 24.5 && rect.maxY <= 24.5, "越界:\(name) \(rect)")
        }
    }

    @Test("语义名映射的目标图标全部存在")
    func mappingTargetsExist() {
        for (symbol, lucide) in IconCatalog.symbolToLucide {
            #expect(IconCatalog.bundledNames.contains(lucide), "\(symbol) → \(lucide) 不存在")
        }
    }

    @Test("Lucide 名可直接使用;未知名返回 nil")
    func lookup() {
        #expect(IconCatalog.lucideName(for: "folder-open") == "folder-open")
        #expect(IconCatalog.lucideName(for: "gearshape") == "settings")
        #expect(IconCatalog.lucideName(for: "no.such.symbol") == nil)
    }

    @Test("许可文件随仓库提供")
    func licensePresent() {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try? String(contentsOf: root.appendingPathComponent("Resources/Licenses/Lucide-LICENSE.txt"), encoding: .utf8)
        #expect(text?.contains("ISC License") == true)
    }
}

@Suite("图标渲染")
@MainActor
struct IconRenderTests {
    /// 把模板图像栅格化并统计非透明像素。
    private func inkPixels(_ image: NSImage, pixels: Int) -> Int {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return 0 }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        var count = 0
        for y in 0..<pixels { for x in 0..<pixels where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.2 { count += 1 } }
        return count
    }

    @Test("渲染结果为模板图像且非空;实心图标比线框墨量更大")
    func rendersInk() {
        let image = OMIconRenderer.nsImage("folder", size: 24)
        #expect(image.isTemplate)
        #expect(inkPixels(image, pixels: 48) > 40)
        let outline = inkPixels(OMIconRenderer.nsImage("square", size: 24), pixels: 48)
        let filled = inkPixels(OMIconRenderer.nsImage("stop.fill", size: 24), pixels: 48)
        #expect(filled > outline)
    }

    @Test("所有语义名都能渲染出墨迹")
    func everySymbolRenders() {
        for symbol in IconCatalog.symbolToLucide.keys.sorted() {
            #expect(inkPixels(OMIconRenderer.nsImage(symbol, size: 16), pixels: 32) > 10, "\(symbol) 渲染为空")
        }
    }

    @Test("缓存复用同一图像;不同尺寸不同图像")
    func caching() {
        let a = OMIconRenderer.nsImage("plus", size: 14)
        let b = OMIconRenderer.nsImage("plus", size: 14)
        let c = OMIconRenderer.nsImage("plus", size: 18)
        #expect(a === b)
        #expect(a !== c)
    }
}

@Suite("源码约束")
struct SourceGuardTests {
    @Test("应用源码中不再使用 SF Symbol(Image(systemName:) / systemImage:)")
    func noSFSymbolsLeft() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appendingPathComponent("Sources")
        let enumerator = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        var offenders: [String] = []
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            // IconKit 自身的回退逻辑允许出现
            if url.path.contains("/IconKit/") { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where line.contains("systemName:") || line.contains("systemImage:") || line.contains("systemSymbolName:") {
                offenders.append("\(url.lastPathComponent):\(index + 1)")
            }
        }
        #expect(offenders.isEmpty, "仍使用 SF Symbol:\(offenders.joined(separator: ", "))")
    }

    @Test("无障碍:用 onTapGesture 充当按钮的行必须声明无障碍特征(紧随其后 10 行内)")
    func tapGesturesAreAccessible() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appendingPathComponent("Sources/OhMyAgentApp")
        let enumerator = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        var offenders: [String] = []
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
            for (index, line) in lines.enumerated() where line.contains(".onTapGesture") {
                // 双击是单击的补充手势;点击空白关闭浮层是纯装饰性的背景手势
                if line.contains("count: 2") || line.contains("dismiss()") { continue }
                let window = lines[index..<min(index + 11, lines.count)]
                if !window.contains(where: { $0.contains("accessibility") }) {
                    offenders.append("\(url.lastPathComponent):\(index + 1)")
                }
            }
        }
        #expect(offenders.isEmpty, "缺少无障碍声明的点击手势:\(offenders.joined(separator: ", "))")
    }

    @Test("无标题栏窗口:禁止使用 windowToolbarStyle / toolbar 修饰符(它们的 NSTitlebarView 会吞掉顶部 32pt 内所有点击)")
    func noWindowToolbar() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appendingPathComponent("Sources/OhMyAgentApp")
        let enumerator = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        var offenders: [String] = []
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
            for (index, line) in lines.enumerated() {
                let code = line.split(separator: "//", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
                if code.contains(".windowToolbarStyle(") || code.contains(".toolbar(removing:") || code.contains("for: .windowToolbar") {
                    offenders.append("\(url.lastPathComponent):\(index + 1)")
                }
            }
        }
        #expect(offenders.isEmpty, "出现会重新引入标题栏工具栏的用法:\(offenders.joined(separator: ", "))")
    }
}
