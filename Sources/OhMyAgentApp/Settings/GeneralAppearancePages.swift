// @author ygw
// 设置页:通用、外观。

import AppKit
import ChatKit
import DesignSystem
import SwiftUI

/// 通用。
struct GeneralPage: View {
    @AppStorage(ClientPrefs.Key.restoreWindows) private var restoreWindows = true
    @AppStorage(ClientPrefs.Key.showDock) private var showDock = true
    @AppStorage(ClientPrefs.Key.showMenuBar) private var showMenuBar = false
    @AppStorage(ClientPrefs.Key.autoUpdate) private var autoUpdate = true
    @AppStorage(ClientPrefs.Key.updateChannel) private var channel = "stable"
    @State private var language = Self.currentLanguage()
    @State private var confirmReset = false
    @State private var restartHint = false

    var body: some View {
        SettingsForm {
            Section("启动") {
                Toggle("启动时恢复上次打开的窗口", isOn: $restoreWindows)
                    .onChange(of: restoreWindows) { _, value in UserDefaults.standard.set(value, forKey: "NSQuitAlwaysKeepsWindows") }
                Picker("语言", selection: $language) {
                    Text("跟随系统").tag("system")
                    Text("简体中文").tag("zh-Hans")
                    Text("English").tag("en")
                }
                .onChange(of: language) { _, value in
                    if value == "system" { UserDefaults.standard.removeObject(forKey: "AppleLanguages") }
                    else { UserDefaults.standard.set([value], forKey: "AppleLanguages") }
                    restartHint = true
                }
                if restartHint { Note("语言在重新启动 OhMyAgent 后生效。") }
            }
            Section("Dock 与菜单栏") {
                Toggle("在 Dock 中显示图标", isOn: $showDock)
                    .onChange(of: showDock) { _, value in
                        NSApp.setActivationPolicy(value ? .regular : .accessory)
                        if !value { showMenuBar = true }
                    }
                Toggle("在菜单栏显示图标", isOn: $showMenuBar)
                    .disabled(!showDock)
                Note("隐藏 Dock 图标时会自动开启菜单栏图标,以便仍可打开窗口。")
            }
            Section("更新") {
                Toggle("自动检查更新", isOn: $autoUpdate)
                Picker("更新通道", selection: $channel) {
                    Text("稳定").tag("stable")
                    Text("预览").tag("preview")
                }
                Note("自动更新机制随发布里程碑(M8)接入,此处先保存你的偏好。")
            }
            Section("重置") {
                Button("重置所有客户端设置…", role: .destructive) { confirmReset = true }
                Note("只重置 OhMyAgent 自身的偏好;Claude Code 的 settings.json 不受影响。")
            }
        }
        .confirmationDialog("重置所有客户端设置?", isPresented: $confirmReset) {
            Button("重置", role: .destructive) {
                ClientPrefs.resetAll()
                AppearanceModel.shared.reset()
                restoreWindows = true; showDock = true; showMenuBar = false; autoUpdate = true; channel = "stable"
                NSApp.setActivationPolicy(.regular)
            }
        } message: {
            Text("外观、编辑器、终端、快捷键等偏好将恢复默认。")
        }
    }

    private static func currentLanguage() -> String {
        (UserDefaults.standard.array(forKey: "AppleLanguages") as? [String])?.first.map { $0.hasPrefix("zh") ? "zh-Hans" : ($0.hasPrefix("en") ? "en" : "system") } ?? "system"
    }
}

/// 外观。
struct AppearancePage: View {
    @Bindable private var appearance = AppearanceModel.shared

    var body: some View {
        SettingsForm {
            Section("主题") {
                Picker("外观", selection: $appearance.theme) { ForEach(AppTheme.allCases) { Text($0.displayName).tag($0) } }
                    .pickerStyle(.segmented)
                Picker("强调色", selection: $appearance.accent) {
                    ForEach(AccentChoice.allCases) { choice in
                        HStack {
                            Circle().fill(choice.color ?? Color.accentColor).frame(width: 10, height: 10)
                            Text(choice.displayName)
                        }.tag(choice)
                    }
                }
            }
            Section("字号") {
                LabeledContent("界面字号 \(Int(appearance.uiFontScale * 100))%") {
                    Slider(value: $appearance.uiFontScale, in: 0.85...1.3, step: 0.05).frame(width: 220)
                }
                LabeledContent("时间线字号 \(Int(appearance.timelineFontScale * 100))%") {
                    Slider(value: $appearance.timelineFontScale, in: 0.85...1.5, step: 0.05).frame(width: 220)
                }
                Text("预览:Claude 的回复会按这个大小显示。`let x = 1`").font(OMFonts.reading).padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(OMColors.card, in: RoundedRectangle(cornerRadius: 8))
            }
            Section("材质与动效") {
                Toggle("始终使用不透明材质", isOn: $appearance.alwaysOpaque)
                Toggle("低电量模式自动改用不透明材质", isOn: $appearance.fallbackOnLowPower)
                Toggle("减弱动效", isOn: $appearance.reduceMotion)
                Toggle("紧凑密度", isOn: $appearance.isCompact)
                Note("系统「减少透明度」「减少动态效果」始终优先。代码、Diff、编辑器等阅读区域恒为纯色,不受影响。")
            }
            Section {
                Button("恢复默认外观") { appearance.reset() }
            }
        }
    }
}
