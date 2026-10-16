// @author ixxxxoooo
// 设置页控件统一守卫:扩展类卡片页的启用开关必须使用 `OMSwitch`(固定 .small),
// 不得再手写 `Toggle("", …)` / `.toggleStyle(.switch)`,也不得把控件放大到 .regular/.large,避免开关与按钮大小不一。

import Foundation
import Testing

@Suite("设置页控件统一守卫")
struct SettingsControlGuardTests {
    /// 仓库根目录(由本文件路径回推)。
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// 受守卫的卡片式扩展页。
    private let guardedFiles = [
        "PluginsManagerView.swift", "MCPManagerView.swift", "AgentExtensionsPage.swift",
        "HooksManagerView.swift", "MarkdownItemManagerView.swift",
    ]

    private func source(_ name: String) throws -> String {
        let url = root.appendingPathComponent("Sources/OhMyAgentApp/Settings/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("扩展页不再手写开关样式,统一使用 OMSwitch")
    func switchesUseOMSwitch() throws {
        for name in guardedFiles {
            let text = try source(name)
            #expect(!text.contains("Toggle(\"\","), "\(name) 应使用 OMSwitch 而不是 Toggle(\"\", …)")
            #expect(!text.contains(".toggleStyle(.switch)"), "\(name) 的开关样式应由 OMSwitch 统一提供")
        }
    }

    @Test("扩展页不放大控件尺寸")
    func noEnlargedControls() throws {
        for name in guardedFiles {
            let text = try source(name)
            #expect(!text.contains(".controlSize(.regular)") && !text.contains(".controlSize(.large)"), "\(name) 不应放大控件")
        }
    }

    @Test("OMSwitch 固定 small 尺寸")
    func omSwitchIsSmall() throws {
        let url = root.appendingPathComponent("Sources/DesignSystem/OMSwitch.swift")
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains(".controlSize(.small)"))
    }
}
