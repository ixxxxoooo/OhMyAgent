// @author ixxxxoooo
// 流式回复渲染基准:模拟一条约 20KB 的助手回复按小片追加,测每一批「解析 → 富文本 → 文本存储 → 排版测量」的主线程耗时。
// 用途:阶段 0 记录基线,之后的优化(按块缓存、尾部增量替换)必须在同一基准上变快;
// 阈值只是「不能退化到比基线更糟」的宽松上限,精确数字看标准错误输出的汇总行。

import AppKit
import ChatKit
import Foundation
import SwiftUI
import Testing

@testable import OhMyAgentApp

/// 基准用的样本文本与度量工具。
@MainActor
enum StreamingBench {
    /// 生成约 `kilobytes` KB 的助手回复(标题、段落、列表、行内代码、引用交替,无围栏代码块,所以是一整段文字块)。
    static func sampleReply(kilobytes: Int) -> String {
        var text = ""
        var index = 0
        while text.utf8.count < kilobytes * 1024 {
            index += 1
            text += "## 第 \(index) 节:流式渲染\n\n"
            text += "这是第 \(index) 段说明文字,包含 `inlineCode` 与 **粗体** 以及 *斜体*,还有一个[链接](https://example.com/\(index))。"
            text += "为了让段落足够长,这里再补充一些中文内容,模拟真实回答里常见的解释性长句。\n\n"
            text += "- 要点一:缓存按块命中\n- 要点二:`NSTextStorage` 只替换尾部\n- 要点三:同宽度下已完成块不再重排\n\n"
            text += "> 引用:第 \(index) 节的小结。\n\n"
        }
        return text
    }

    /// 把全文切成约 `chunk` 个字符一片(模拟流式 token 批)。
    static func chunks(of text: String, size chunk: Int) -> [String] {
        var result: [String] = []
        var current = text.startIndex
        while current < text.endIndex {
            let next = text.index(current, offsetBy: chunk, limitedBy: text.endIndex) ?? text.endIndex
            result.append(String(text[current..<next]))
            current = next
        }
        return result
    }

    /// 统计:中位数、P95、最大、总和(毫秒)。
    struct Stats: CustomStringConvertible {
        var samples: [Double]
        var median: Double { sorted[sorted.count / 2] }
        var p95: Double { sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))] }
        var max: Double { sorted.last ?? 0 }
        var total: Double { samples.reduce(0, +) }
        private var sorted: [Double] { samples.sorted() }
        var description: String {
            String(format: "批数 %d  中位 %.3fms  P95 %.3fms  最大 %.3fms  合计 %.1fms", samples.count, median, p95, max, total)
        }
    }

    /// 以毫秒计时一段同步代码。
    static func timeMs(_ body: () -> Void) -> Double {
        let start = ContinuousClock.now
        body()
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
    }

    /// 向标准错误输出一行基准结果(测试里不走 OMLog,便于脚本直接抓取)。
    static func report(_ label: String, _ stats: Stats) {
        FileHandle.standardError.write(Data("[基准] \(label): \(stats)\n".utf8))
    }
}

@MainActor
@Suite("流式渲染基准", .serialized)
struct StreamingRenderBenchTests {
    /// 当前实现的一批更新:与视图层 `MarkdownView` → `MarkdownTextRunView` → `updateNSView` 同一路径。
    @MainActor
    private final class Pipeline {
        let view = MarkdownTextRepresentable.makeTextView()
        let renderer = MarkdownTextRunRenderer()

        /// 处理一批:解析 + 渲染文字段 + 测量高度。
        func step(_ text: String, width: CGFloat) {
            let blocks = MarkdownCache.blocks(for: text, streaming: true)
            for segment in MarkdownSegment.split(blocks) {
                if case .textRun(let run) = segment {
                    renderer.apply(run, to: view)
                    _ = MarkdownTextRepresentable.measure(view, width: width)
                }
            }
        }
    }

    @Test("20KB 流式回复:每批主线程耗时(基线/优化后对比用)")
    func streamingTwentyKilobytes() {
        MarkdownCache.reset()
        let full = StreamingBench.sampleReply(kilobytes: 20)
        let pieces = StreamingBench.chunks(of: full, size: 48)
        let pipeline = Pipeline()
        var prefix = ""
        var samples: [Double] = []
        for piece in pieces {
            prefix += piece
            samples.append(StreamingBench.timeMs { pipeline.step(prefix, width: 700) })
        }
        let stats = StreamingBench.Stats(samples: samples)
        StreamingBench.report("20KB 流式(48 字/批)", stats)
        // 后半程(文本最长时)的批耗时,是用户最容易感到卡的阶段
        let tail = StreamingBench.Stats(samples: Array(samples.suffix(samples.count / 4)))
        StreamingBench.report("20KB 流式 · 最后 25%", tail)
        #expect(stats.total > 0)
        #expect(pipeline.view.string.contains("流式渲染"))
    }
}
