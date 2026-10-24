// @author ixxxxoooo
// 切换闪烁探针的逐帧采样器:每个显示刷新取窗口内容的低分辨率亮度网格,
// 切换后统计「连续多帧都在变化」的片段(A→中间态→B 即为闪烁),并把这些帧存成 PNG 供肉眼核对。

import AppKit
import Foundation

@MainActor
final class IDEFrameSampler: NSObject {
    private struct Frame { var time: Double; var grid: [Float]; var image: NSImage? }
    private let view: NSView
    private var link: CADisplayLink?
    private var frames: [Frame] = []
    private var marks: [(Double, String)] = []
    private let start = CACurrentMediaTime()
    private let gridW = 96, gridH = 54

    /// - Parameter view: 被采样的窗口内容视图
    init(view: NSView) {
        self.view = view
        super.init()
        link = view.displayLink(target: self, selector: #selector(tick))
        link?.add(to: .main, forMode: .common)
    }

    /// 记录一次「切换」事件的时刻。
    func mark(_ name: String) { marks.append((CACurrentMediaTime() - start, name)) }

    @objc private func tick() {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        let w = rep.pixelsWide, h = rep.pixelsHigh
        var grid = [Float](repeating: 0, count: gridW * gridH)
        // 直接读像素缓冲区(逐点 colorAt 太慢,会拖慢主线程并扭曲被测的切换时序)
        if let data = rep.bitmapData {
            let bpp = rep.bitsPerPixel / 8, stride = rep.bytesPerRow
            for gy in 0..<gridH {
                for gx in 0..<gridW {
                    let p = data + (gy * h / gridH + h / gridH / 2) * stride + (gx * w / gridW + w / gridW / 2) * bpp
                    grid[gy * gridW + gx] = 0.299 * Float(p[0]) + 0.587 * Float(p[1]) + 0.114 * Float(p[2])
                }
            }
        }
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        frames.append(Frame(time: CACurrentMediaTime() - start, grid: grid, image: image))
    }

    /// 停止采样并把分析结果与可疑帧写到 `dir`。
    /// - Returns: 汇总文本
    func finish(into dir: String) -> String {
        link?.invalidate()
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var report = "frames=\(frames.count) marks=\(marks.count)\n"
        func changed(_ a: [Float], _ b: [Float]) -> Int { zip(a, b).filter { abs($0 - $1) > 12 }.count }
        for (index, mark) in marks.enumerated() {
            let from = frames.firstIndex { $0.time >= mark.0 - 0.02 } ?? 0
            let to = frames.lastIndex { $0.time <= mark.0 + 0.6 } ?? from
            guard to > from + 1 else { continue }
            var line = "[\(index)] \(mark.1) @\(String(format: "%.2f", mark.0))s 变化格数:"
            var run = 0, maxRun = 0
            for k in (from + 1)...to {
                let c = changed(frames[k - 1].grid, frames[k].grid)
                line += " \(c)"
                if c > 3 { run += 1; maxRun = max(maxRun, run) } else { run = 0 }
            }
            report += line + "  连续变化帧=\(maxRun)\n"
            if maxRun >= 2 || ProcessInfo.processInfo.environment["OMA_SWITCH_DUMP_ALL"] == "1" {
                for k in from...to {
                    guard let tiff = frames[k].image?.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { continue }
                    try? png.write(to: URL(fileURLWithPath: "\(dir)/m\(index)_f\(k - from).png"))
                }
            }
        }
        return report
    }
}
