// @author ixxxxoooo
// 卡顿栈采样测试:节流策略、启用开关、`sample` 输出解析(主线程最重路径)。

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
