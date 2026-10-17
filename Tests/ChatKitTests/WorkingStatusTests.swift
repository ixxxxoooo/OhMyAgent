// @author ixxxxoooo
// 等待文案:动词稳定挑选、耗时格式化、整行文案。

import Foundation
import Testing
@testable import ChatKit

@Suite("等待文案")
struct WorkingStatusTests {
    @Test("动词按种子稳定挑选且支持负数种子")
    func verbSelection() {
        #expect(WorkingStatus.verb(seed: 3) == WorkingStatus.verb(seed: 3))
        #expect(WorkingStatus.verb(seed: 0) == WorkingStatus.verb(seed: WorkingStatus.verbs.count))
        #expect(!WorkingStatus.verb(seed: -7).isEmpty)
    }

    @Test("动画帧循环")
    func glyphLoop() {
        #expect(WorkingStatus.glyph(tick: 0) == WorkingStatus.glyph(tick: WorkingStatus.glyphFrames.count))
        #expect(!WorkingStatus.glyph(tick: -1).isEmpty)
    }

    @Test("耗时格式化")
    func elapsed() {
        #expect(WorkingStatus.elapsed(-5) == "0s")
        #expect(WorkingStatus.elapsed(12) == "12s")
        #expect(WorkingStatus.elapsed(65) == "1m 05s")
        #expect(WorkingStatus.elapsed(3720) == "1h 02m")
    }

    @Test("整行文案包含耗时与中断提示")
    func line() {
        let text = WorkingStatus.line(verb: "思考中", seconds: 12, canInterrupt: true)
        #expect(text.hasPrefix("思考中… (12s"))
        #expect(text.contains("Esc"))
        #expect(!WorkingStatus.line(verb: "思考中", seconds: 3, canInterrupt: false).contains("Esc"))
    }
}

@Suite("任务坞分区选择")
struct ComposerDockSectionTests {
    @Test("优先用户选中的非空分区;否则回退到第一个非空分区;收起或全空返回 nil")
    func effective() {
        let counts: [ComposerDockSection: Int] = [.queued: 0, .subagents: 2, .terminals: 1]
        #expect(ComposerDockSection.effective(selection: .terminals, hidden: false, counts: counts) == .terminals)
        #expect(ComposerDockSection.effective(selection: .queued, hidden: false, counts: counts) == .subagents)
        #expect(ComposerDockSection.effective(selection: nil, hidden: false, counts: counts) == .subagents)
        #expect(ComposerDockSection.effective(selection: .terminals, hidden: true, counts: counts) == nil)
        #expect(ComposerDockSection.effective(selection: nil, hidden: false, counts: [:]) == nil)
    }
}

@Suite("等待动词风格与滚动条设置")
struct WorkingVerbStyleTests {
    @Test("每种风格都有动词与动画帧,动词互不重复,极简只有一个")
    func catalog() {
        for style in WorkingVerbStyle.allCases {
            #expect(!style.verbs.isEmpty && !style.glyphFrames.isEmpty && !style.restingGlyph.isEmpty)
            #expect(Set(style.verbs).count == style.verbs.count, "\(style.rawValue) 动词重复")
        }
        #expect(WorkingVerbStyle.minimal.verbs.count == 1)
        #expect(WorkingVerbStyle.classic.verbs == WorkingStatus.verbs)
    }

    @Test("按风格挑选动词:同种子稳定,且来自该风格的动词表")
    func verbForStyle() {
        for style in WorkingVerbStyle.allCases {
            let verb = WorkingStatus.verb(seed: 5, style: style)
            #expect(verb == WorkingStatus.verb(seed: 5, style: style))
            #expect(style.verbs.contains(verb))
        }
        #expect(WorkingStatus.glyph(tick: 0, style: .geek) == WorkingVerbStyle.geek.glyphFrames[0])
    }

    @Test("存储值解析:未知或缺省回退经典/跟随系统")
    func resolve() {
        #expect(WorkingVerbStyle.resolve("poetic") == .poetic)
        #expect(WorkingVerbStyle.resolve("???") == .classic)
        #expect(WorkingVerbStyle.resolve(nil) == .classic)
        #expect(ScrollbarVisibility.resolve("autoHide") == .autoHide)
        #expect(ScrollbarVisibility.resolve("x") == .custom)
        #expect(ScrollbarVisibility.resolve("system") == .system)
        let defaults = UserDefaults(suiteName: "WorkingVerbStyleTests")!
        defer { defaults.removePersistentDomain(forName: "WorkingVerbStyleTests") }
        defaults.set("geek", forKey: ClientPrefs.Key.workingVerbStyle)
        #expect(WorkingVerbStyle.current(defaults) == .geek)
        defaults.set("always", forKey: ClientPrefs.Key.scrollbarVisibility)
        #expect(ScrollbarVisibility.current(defaults) == .always)
    }
}
