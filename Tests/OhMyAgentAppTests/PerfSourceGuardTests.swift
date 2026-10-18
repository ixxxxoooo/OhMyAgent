// @author ixxxxoooo
// 性能源码守卫:防止已修复的卡顿根因被无意中改回去(侧栏整体动画、隐藏标签随容器重排、逐帧时间线动画)。

import Foundation
import Testing

@Suite("性能源码守卫")
struct PerfSourceGuardTests {
    private static var sources: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/OhMyAgentApp")
    }

    /// 读取文件并去掉行内注释,返回 (文件名, 行号, 代码) 序列。
    private static func codeLines(_ name: String) throws -> [(line: Int, code: String)] {
        let text = try String(contentsOf: sources.appendingPathComponent(name), encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: false).enumerated().map { index, line in
            (index + 1, line.split(separator: "//", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? "")
        }
    }

    @Test("侧栏显隐不得给整个 HStack 加动画(会让中栏与全部会话每帧重排),动画只绑在面板过渡上")
    func panelToggleAnimationStaysOnTransition() throws {
        let lines = try Self.codeLines("WorkbenchView.swift")
        let offenders = lines.filter { $0.code.contains(".animation(") && $0.code.contains("panelVisibilitySignature") }
        #expect(offenders.isEmpty, "WorkbenchView 第 \(offenders.map(\.line)) 行:整体动画会带动中栏逐帧重排")
        #expect(lines.contains { $0.code.contains(".animation(Self.panelToggleAnimation)") }, "面板过渡应自带动画")
    }

    @Test("保活的隐藏标签必须冻结布局尺寸")
    func inactiveTabsAreFrozen() throws {
        let lines = try Self.codeLines("Dock/TabGroupView.swift")
        #expect(lines.contains { $0.code.contains("InactiveSizeFreeze(isActive:") }, "TabGroupView 应对保活标签应用 InactiveSizeFreeze")
    }

    @Test("持续动画一律走 Core Animation:禁止逐帧 TimelineView(.animation)、phaseAnimator、repeatForever 显式动画")
    func noPerFrameLoopAnimations() throws {
        let root = Self.sources.deletingLastPathComponent().deletingLastPathComponent()
        var offenders: [String] = []
        for dir in ["Sources/OhMyAgentApp", "Sources/DesignSystem"] {
            let enumerator = FileManager.default.enumerator(at: root.appendingPathComponent(dir), includingPropertiesForKeys: nil)
            while let url = enumerator?.nextObject() as? URL {
                guard url.pathExtension == "swift" else { continue }
                let text = try String(contentsOf: url, encoding: .utf8)
                for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                    let code = line.split(separator: "//", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
                    if code.contains("TimelineView(.animation") || code.contains(".phaseAnimator(") || code.contains(".repeatForever(") {
                        offenders.append("\(url.lastPathComponent):\(index + 1)")
                    }
                }
            }
        }
        #expect(offenders.isEmpty, "出现逐帧/SwiftUI 驱动的循环动画(应改用 DesignSystem/LoopLayers.swift):\(offenders.joined(separator: ", "))")
    }
}
