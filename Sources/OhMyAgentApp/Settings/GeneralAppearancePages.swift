// @author ixxxxoooo
// 设置页:通用、外观。

import AppKit
import ChatKit
import DesignSystem
import SwiftUI

/// 通用。
struct GeneralPage: View {
    @AppStorage(ClientPrefs.Key.restoreWindows) private var restoreWindows = true
    @AppStorage(ClientPrefs.Key.showDock) private var showDock = true
    @AppStorage(ClientPrefs.Key.showMenuBar) private var showMenuBar = true
    @AppStorage(ClientPrefs.Key.notifyFinished) private var notifyFinished = true
    @AppStorage(ClientPrefs.Key.notifySound) private var notifySound = true
    @AppStorage(ClientPrefs.Key.sendKey) private var sendKey = SendKey.enter.rawValue
    @AppStorage(ClientPrefs.Key.runningSend) private var runningSend = RunningSendMode.steer.rawValue
    @AppStorage(ClientPrefs.Key.autoUpdate) private var autoUpdate = true
    @AppStorage(ClientPrefs.Key.updateChannel) private var channel = "stable"
    @AppStorage(ClientPrefs.Key.updateFeedURL) private var feedURL = ""
    @State private var updates = UpdateModel.shared
    @State private var language = Self.currentLanguage()
    @State private var confirmReset = false
    @State private var restartHint = false

    /// 更新检查状态文案。
    @ViewBuilder
    private var updateStatus: some View {
        switch updates.state {
        case .idle: EmptyView()
        case .checking: ProgressView().controlSize(.small)
        case .result(.upToDate): Text("已是最新版本").foregroundStyle(.secondary)
        case .result(.available(let info)):
            Button("下载 \(info.version)") { updates.openDownload(info) }
            if let notes = info.notes { Text(notes).foregroundStyle(.secondary).lineLimit(1) }
        case .result(.unsupportedSystem(let info)): Text("\(info.version) 需要 macOS \(info.minimumSystemVersion ?? "")").foregroundStyle(.orange)
        case .result(.failed(let message)): Text(message).foregroundStyle(.red).lineLimit(2)
        }
    }

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
            Section("输入") {
                Picker("发送键", selection: $sendKey) {
                    Text("Return 发送,Shift+Return 换行").tag(SendKey.enter.rawValue)
                    Text("⌘Return 发送,Return 换行").tag(SendKey.commandEnter.rawValue)
                }
                Picker("Agent 运行中发送消息", selection: $runningSend) {
                    Text("引导当前轮次").tag(RunningSendMode.steer.rawValue)
                    Text("排到本轮结束后").tag(RunningSendMode.queue.rawValue)
                }
                Note("「引导」会把消息立刻注入正在进行的轮次(Agent 不支持时自动排队);「排队」等本轮结束后再发送。")
            }
            Section("Dock 与菜单栏") {
                Toggle("在 Dock 中显示图标", isOn: $showDock)
                    .onChange(of: showDock) { _, value in
                        NSApp.setActivationPolicy(value ? .regular : .accessory)
                        if !value { showMenuBar = true }
                    }
                Toggle("在菜单栏显示图标", isOn: $showMenuBar)
                    .disabled(!showDock)
                Note("隐藏 Dock 图标时会自动开启菜单栏图标,以便仍可打开窗口。关闭最后一个窗口后,应用会继续在菜单栏中运行(⌘Q 退出)。")
                Toggle("任务完成时发送系统通知", isOn: $notifyFinished)
                Toggle("通知带提示音", isOn: $notifySound).disabled(!notifyFinished)
                Note("运行中的会话在菜单栏图标上显示闪烁的点;完成后点常亮,打开对应会话或点击通知后消失。")
            }
            Section("更新") {
                Toggle("自动检查更新", isOn: $autoUpdate)
                Picker("更新通道", selection: $channel) {
                    Text("稳定").tag("stable")
                    Text("预览").tag("preview")
                }
                TextField("更新源地址 (https)", text: $feedURL, prompt: Text("https://example.com/oma/appcast.json"))
                    .textFieldStyle(.roundedBorder)
                LabeledContent("当前版本", value: "\(updates.currentVersion) (\(updates.currentBuild))")
                HStack {
                    Button("立即检查") { updates.checkNow() }.disabled(updates.state == .checking)
                    updateStatus
                }
                Note("发现新版本后在浏览器中下载 Developer ID 公证的安装包;发布源格式见 开发进度.md。")
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
                restoreWindows = true; showDock = true; showMenuBar = true; notifyFinished = true; notifySound = true; sendKey = SendKey.enter.rawValue; runningSend = RunningSendMode.steer.rawValue; autoUpdate = true; channel = "stable"
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

/// 主题:主题包、强调色、聊天宽度、字号、材质与动效。
struct AppearancePage: View {
    @Bindable private var appearance = AppearanceModel.shared
    @AppStorage(ClientPrefs.Key.chatWidth) private var chatWidth = ChatWidth.standard.rawValue
    @AppStorage(ClientPrefs.Key.chatWidthCustom) private var chatWidthCustom = ChatWidth.customDefault

    var body: some View {
        SettingsForm {
            Section("主题") {
                ForEach(ThemeGroup.allCases, id: \.self) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(group.title).font(OMFonts.small).foregroundStyle(OMColors.secondaryText)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 8)], alignment: .leading, spacing: 8) {
                            ForEach(ThemePackage.all.filter { $0.group == group }) { package in
                                ThemeCard(package: package, selected: appearance.themeID == package.id) {
                                    appearance.themeID = package.id
                                }
                            }
                        }
                    }
                }
                Picker("模式", selection: $appearance.theme) { ForEach(AppTheme.allCases) { Text($0.displayName).tag($0) } }
                    .pickerStyle(.segmented)
                    .disabled(appearance.themePackage.tone != .system)
                Note("「模式」只在主题为「跟随系统」时可选;其余主题自带明暗。")
            }
            Section("强调色") {
                AccentPicker(title: "主强调色", choice: $appearance.accent, hex: $appearance.customAccentHex)
                AccentPicker(title: "第二强调色", choice: $appearance.accent2, hex: $appearance.customAccent2Hex)
                AccentPreview().id(appearance.themeRevision)
                Note("主强调色用于按钮与选中态;第二强调色用于链接与次要徽标。「跟随主题」使用所选主题的默认配色。")
            }
            Section("聊天宽度") {
                Picker("内容宽度", selection: $chatWidth) {
                    ForEach(ChatWidth.allCases) { width in
                        Text(width.displayName).tag(width.rawValue)
                    }
                }
                if chatWidth == ChatWidth.custom.rawValue {
                    LabeledContent("自定义宽度 \(Int(ChatWidth.clampedCustom(chatWidthCustom))) pt") {
                        Slider(value: $chatWidthCustom, in: ChatWidth.customRange, step: ChatWidth.customStep).frame(width: 220)
                    }
                } else if ChatWidth(rawValue: chatWidth) != .full {
                    LabeledContent("当前宽度", value: "\(Int(ChatWidth.resolve(raw: chatWidth, custom: chatWidthCustom))) pt")
                }
                Note("控制会话时间线与输入框的最大宽度;窄屏或分屏时会自动收窄。")
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
                Button("恢复默认主题") { appearance.reset(); chatWidth = ChatWidth.standard.rawValue; chatWidthCustom = ChatWidth.customDefault }
            }
        }
    }
}

/// 主题卡片:迷你色板 + 名称,选中时描边。
private struct ThemeCard: View {
    let package: ThemePackage
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                swatch
                    .frame(height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(OMColors.hairline, lineWidth: 0.5))
                HStack(spacing: 4) {
                    Text(package.name).font(OMFonts.small).lineLimit(1)
                    Spacer(minLength: 0)
                    if selected { Image.om("check", size: 11).foregroundStyle(OMColors.accent) }
                }
            }
            .padding(6)
            .background(selected ? OMColors.accent.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(selected ? OMColors.accent : OMColors.hairline.opacity(0.6), lineWidth: selected ? 1.5 : 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(package.name)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    /// 迷你预览:左半底色 + 卡片条 + 强调色点。
    @ViewBuilder private var swatch: some View {
        if let palette = package.palette {
            ZStack(alignment: .leading) {
                palette.surface.color
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 3).fill(palette.card.color).frame(width: 34, height: 22)
                    VStack(alignment: .leading, spacing: 3) {
                        Capsule().fill(palette.editorForeground.color.opacity(0.7)).frame(width: 40, height: 3)
                        Capsule().fill(palette.comment.color).frame(width: 26, height: 3)
                    }
                    Spacer(minLength: 0)
                    HStack(spacing: 3) {
                        Circle().fill(palette.accent.color).frame(width: 9, height: 9)
                        Circle().fill(palette.accent2.color).frame(width: 9, height: 9)
                    }
                }
                .padding(.horizontal, 7)
            }
        } else {
            HStack(spacing: 0) {
                Color.white
                Color(white: 0.12)
            }
            .overlay(Image.om("monitor", size: 14).foregroundStyle(.gray))
        }
    }
}

/// 强调色选择行:预设色圆点 + 「跟随主题」+ 自定义取色。
private struct AccentPicker: View {
    let title: LocalizedStringKey
    @Binding var choice: AccentChoice
    @Binding var hex: String

    private var customColor: Binding<Color> {
        Binding(
            get: { ThemeRGB(hexString: hex)?.color ?? .gray },
            set: { newValue in
                if let srgb = NSColor(newValue).usingColorSpace(.sRGB) {
                    hex = ThemeRGB(red: srgb.redComponent, green: srgb.greenComponent, blue: srgb.blueComponent).hexString
                    choice = .custom
                }
            }
        )
    }

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                ForEach(AccentChoice.allCases.filter { $0 != .custom }) { item in
                    Button { choice = item } label: {
                        ZStack {
                            if let color = item.color {
                                Circle().fill(color)
                            } else {
                                Circle().strokeBorder(OMColors.secondaryText, style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                            }
                            if choice == item { Circle().strokeBorder(Color.primary, lineWidth: 2).padding(-3) }
                        }
                        .frame(width: 16, height: 16)
                    }
                    .buttonStyle(.plain)
                    .help(item.displayName)
                    .accessibilityLabel(item.displayName)
                    .accessibilityAddTraits(choice == item ? [.isSelected] : [])
                }
                ColorPicker("自定义", selection: customColor, supportsOpacity: false)
                    .labelsHidden()
                    .help("自定义颜色")
            }
        }
    }
}

/// 强调色预览条:按钮、链接、徽标与 Diff 色。
private struct AccentPreview: View {
    var body: some View {
        HStack(spacing: 10) {
            Text("主按钮").font(OMFonts.small).foregroundStyle(.white)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(OMColors.accent, in: Capsule())
            Text("链接示例").font(OMFonts.small).foregroundStyle(OMColors.accent2).underline()
            Tag("徽标", color: OMColors.accent2)
            Tag("新增", color: OMColors.diffAdded)
            Tag("删除", color: OMColors.danger)
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(OMColors.card, in: RoundedRectangle(cornerRadius: 8))
    }
}
