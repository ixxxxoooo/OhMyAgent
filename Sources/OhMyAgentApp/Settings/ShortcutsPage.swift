// @author ixxxxoooo
// 设置页:快捷键(录制、冲突提示、导入导出)。

import IconKit
import AppKit
import DesignSystem
import SwiftUI

/// 快捷键页。
struct ShortcutsPage: View {
    private let store = ShortcutStore.shared
    @State private var recording: ShortcutAction?
    @State private var monitor: Any?
    @State private var message: String?

    var body: some View {
        SettingsForm {
            Section("可自定义") {
                ForEach(ShortcutAction.allCases) { action in
                    HStack {
                        Text(action.title)
                        Spacer()
                        Button(recording == action ? String(localized: "按下新的组合键…(Esc 取消)") : store.binding(for: action).display) { toggleRecording(action) }
                            .buttonStyle(.bordered)
                            .font(OMFonts.mono)
                        Button { store.reset(action) } label: { Image.om("arrow.uturn.backward") }
                            .buttonStyle(.borderless).help("恢复默认 \(action.defaultBinding.display)").accessibilityLabel("恢复 \(action.title) 的默认快捷键")
                            .disabled(store.binding(for: action) == action.defaultBinding)
                    }
                }
                if let message { Label(message, om: "exclamationmark.triangle").font(OMFonts.small).foregroundStyle(OMColors.warning) }
                Note("组合键必须包含 ⌘、⌃ 或 ⌥ 之一。与系统保留键或其他动作冲突时会拒绝并提示。")
            }
            Section("固定快捷键") {
                ForEach(Self.fixed, id: \.0) { LabeledContent($0.0, value: $0.1) }
            }
            Section("导入 / 导出") {
                HStack {
                    Button("导出…", action: export)
                    Button("导入…", action: importFile)
                }
            }
        }
        .onDisappear(perform: stopRecording)
    }

    private static let fixed: [(String, String)] = [
        (String(localized: "换行"), "⇧↩ / ⌥↩"), (String(localized: "取消生成 / 关闭补全"), "Esc"), (String(localized: "切换模式"), "⇧⇥"), (String(localized: "补全选择"), "↑ ↓ ⇥ ↩"), (String(localized: "设置"), "⌘,"),
    ]

    private func toggleRecording(_ action: ShortcutAction) {
        if recording == action { stopRecording(); return }
        stopRecording()
        recording = action
        message = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { stopRecording(); return nil }
            guard let binding = ShortcutBinding(event: event) else { return nil }
            message = store.set(binding, for: action)
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = nil
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "OhMyAgent-shortcuts.json"
        guard panel.runModal() == .OK, let url = panel.url, let data = store.exportJSON() else { return }
        try? data.write(to: url)
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        let result = store.importJSON(data)
        message = result.skipped.isEmpty ? nil : String(localized: "已导入 \(result.imported) 项;跳过:") + result.skipped.joined(separator: ";")
    }
}
