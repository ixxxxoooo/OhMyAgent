// @author ixxxxoooo
// 卡顿栈采样测试:节流策略、启用开关、栈聚合、文件清理规则、进程内主线程探针、旧 `sample` 输出解析。

import Foundation
import Testing
@testable import OMLog

@Suite("卡顿栈采样")
struct HitchStackSamplerTests {
    @Test("策略:阈值、间隔与次数上限")
    func policy() {
        let policy = HitchSamplePolicy(stallThresholdMs: 250, minGapMs: 4000, maxSamples: 2)
        #expect(!policy.shouldSample(stalledMs: 100, sinceLastMs: nil, taken: 0))
        #expect(policy.shouldSample(stalledMs: 250, sinceLastMs: nil, taken: 0))
        #expect(!policy.shouldSample(stalledMs: 900, sinceLastMs: 1000, taken: 1))
        #expect(policy.shouldSample(stalledMs: 900, sinceLastMs: 5000, taken: 1))
        #expect(!policy.shouldSample(stalledMs: 900, sinceLastMs: 9000, taken: 2))
    }

    @Test("策略:非法参数被钳制")
    func clamped() {
        let policy = HitchSamplePolicy(stallThresholdMs: -5, minGapMs: -1, maxSamples: -3)
        #expect(policy.stallThresholdMs == 50)
        #expect(policy.minGapMs == 0)
        #expect(policy.maxSamples == 0)
    }

    @Test("启用开关:显式值优先,演示模式与开发版默认开启")
    func enabled() {
        #expect(!HitchStackSampler.isEnabled(environment: [:]))
        #expect(HitchStackSampler.isEnabled(environment: ["OMA_HITCH_SAMPLE": "1"]))
        #expect(HitchStackSampler.isEnabled(environment: ["OMA_DEMO": "1"]))
        #expect(HitchStackSampler.isEnabled(environment: ["OMA_DEV": "1"]))
        #expect(!HitchStackSampler.isEnabled(environment: ["OMA_DEMO": "1", "OMA_HITCH_SAMPLE": "0"]))
    }

    @Test("策略:正式版 150ms 开始采并落盘;开发版 120ms 全落盘")
    func environmentPolicy() {
        let release = HitchSamplePolicy.forEnvironment([:])
        #expect(release.stallThresholdMs == 150)
        #expect(release.persistThresholdMs == 150)
        let dev = HitchSamplePolicy.forEnvironment(["OMA_DEV": "1"])
        #expect(dev.stallThresholdMs == 120)
        #expect(dev.persistThresholdMs == 120)
        #expect(HitchStackSampler.isSamplingAllowed(environment: [:]))
        #expect(!HitchStackSampler.isSamplingAllowed(environment: ["OMA_HITCH_SAMPLE": "0"]))
    }

    @Test("模态循环:runModal / _doModalLoop 视为等待用户,普通栈不是")
    func modalFilter() {
        #expect(HitchModalFilter.isModal(["main (in OhMyAgent)", "-[NSApplication runModalForWindow:] (in AppKit)"]))
        #expect(HitchModalFilter.isModal(["-[NSApplication _doModalLoop:peek:] (in AppKit)"]))
        #expect(!HitchModalFilter.isModal(["main (in OhMyAgent)", "CA::Transaction::commit (in QuartzCore)"]))
        #expect(!HitchModalFilter.isModal([]))
    }

    @Test("聚合:同栈计数、空栈忽略、按次数排序")
    func aggregator() {
        var aggregator = HitchStackAggregator()
        aggregator.add([1, 2, 3])
        aggregator.add([1, 2, 3])
        aggregator.add([9, 2, 3])
        aggregator.add([])
        #expect(aggregator.total == 3)
        let top = aggregator.top(5)
        #expect(top.count == 2)
        #expect(top[0].frames == [1, 2, 3] && top[0].count == 2)
        #expect(aggregator.top(1).count == 1)
    }

    @Test("聚合:不同栈数量有上限")
    func aggregatorCap() {
        var aggregator = HitchStackAggregator(maxDistinct: 2)
        for index in 1...5 { aggregator.add([UInt(index)]) }
        #expect(aggregator.top(10).count == 2)
        #expect(aggregator.total == 5)
    }

    @Test("文件名:带总时长,可解析;旧格式为 nil")
    func fileNames() {
        let name = HitchSampleFiles.fileName(pid: 12, sequence: 3, totalMs: 37062)
        #expect(name == "hitch-12-3-37062ms.txt")
        #expect(HitchSampleFiles.totalMs(of: name) == 37062)
        #expect(HitchSampleFiles.totalMs(of: "hitch-12-3.txt") == nil)
    }

    @Test("清理:短卡顿保留最近 N 份,长卡顿单独限量")
    func pruning() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        var files: [(name: String, modified: Date)] = []
        for index in 0..<5 { files.append((HitchSampleFiles.fileName(pid: 1, sequence: index, totalMs: 300), base.addingTimeInterval(Double(index)))) }
        for index in 0..<3 { files.append((HitchSampleFiles.fileName(pid: 1, sequence: 10 + index, totalMs: 9000), base.addingTimeInterval(Double(index)))) }
        files.append(("other.log", base))
        let victims = HitchSampleFiles.victims(files: files, shortLimit: 2, longLimit: 2)
        #expect(Set(victims) == ["hitch-1-0-300ms.txt", "hitch-1-1-300ms.txt", "hitch-1-2-300ms.txt", "hitch-1-10-9000ms.txt"])
    }

    @Test("探针:后台线程能抓到被阻塞主线程的栈并符号化")
    @MainActor
    func probeCapturesMainThread() {
        guard let probe = MainThreadStackProbe() else { Issue.record("主线程上应能创建探针"); return }
        let box = ProbeResult()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            let capacity = 64
            let buffer = UnsafeMutablePointer<UInt>.allocate(capacity: capacity)
            defer { buffer.deallocate() }
            // 主线程此刻正阻塞在 semaphore.wait,栈里至少有若干帧
            let count = probe.capture(into: buffer, capacity: capacity)
            box.frames = Array(UnsafeBufferPointer(start: buffer, count: count))
            done.signal()
        }
        done.wait()
        #expect(box.frames.count >= 3)
        #expect(box.frames.allSatisfy { $0 != 0 })
        #expect(!StackSymbolizer.describe(box.frames[0]).isEmpty)
    }

    /// 精简的 `sample` 输出样例:主线程两条分支,左分支 800 次更重;另有一个非主线程。
    private let fixture = """
    Analysis of sampling OhMyAgent (pid 1) every 10 milliseconds
    Call graph:
        1000 Thread_1   DispatchQueue_1: com.apple.main-thread  (serial)
        + 1000 start  (in dyld) + 6992  [0x1]
        +   1000 main  (in OhMyAgent) + 12  [0x2]
        +     800 layoutSubtree  (in SwiftUI) + 100  [0x3]
        +     ! 700 heavyWork  (in OhMyAgent) + 4  [0x4]
        +     ! 100 other  (in SwiftUI) + 4  [0x5]
        +     200 idle  (in AppKit) + 1  [0x6]
        1000 Thread_2: com.apple.NSEventThread
        + 1000 mach_msg  (in libsystem_kernel.dylib) + 8  [0x7]

    Total number in stack (recursive counted multiple, when >=5):
    """

    @Test("解析:取主线程最重路径并精简帧描述")
    func heaviestPath() {
        let path = HitchSampleParser.heaviestMainPath(in: fixture)
        #expect(path.first == "start  (in dyld)")
        #expect(path.contains("heavyWork  (in OhMyAgent)"))
        #expect(path.last == "heavyWork  (in OhMyAgent)")
        #expect(!path.contains { $0.contains("mach_msg") })
        #expect(!path.contains { $0.contains("[0x") })
    }

    @Test("解析:只保留靠近叶子的 maxFrames 帧;无主线程时为空")
    func trimmedAndMissing() {
        #expect(HitchSampleParser.heaviestMainPath(in: fixture, maxFrames: 2).count == 2)
        #expect(HitchSampleParser.heaviestMainPath(in: "nothing here").isEmpty)
    }
}

/// 探针测试用的跨线程结果盒(信号量保证读写有序)。
private final class ProbeResult: @unchecked Sendable {
    var frames: [UInt] = []
}
