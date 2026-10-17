// @author ixxxxoooo
// 设置页:通用、外观。

import AppKit
import ChatKit
import DesignSystem
import SwiftUI
import WorkbenchKit

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
        case .result(.upToDate): Text("已是最新版本").foregroundStyle(OMColors.secondaryText)
        case .result(.available(let info)):
            Button("下载 \(info.version)") { updates.openDownload(info) }
            if let notes = info.notes { Text(notes).foregroundStyle(OMColors.secondaryText).lineLimit(1) }
        case .result(.unsupportedSystem(let info)): Text("\(info.version) 需要 macOS \(info.minimumSystemVersion ?? "")").foregroundStyle(OMColors.warning)
        case .result(.failed(let message)): Text(message).foregroundStyle(OMColors.danger).lineLimit(2)
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

/// 外观:主题包、强调色、聊天宽度、字号、材质与动效、面板布局。
struct AppearancePage: View {
    @Bindable private var appearance = AppearanceModel.shared
    @AppStorage(ClientPrefs.Key.chatWidth) private var chatWidth = ChatWidth.standard.rawValue
    @AppStorage(ClientPrefs.Key.chatWidthCustom) private var chatWidthCustom = ChatWidth.customDefault
    @AppStorage(ClientPrefs.Key.settingsWidth) private var settingsWidth = SettingsContentWidth.standard.rawValue
    @AppStorage(ClientPrefs.Key.settingsWidthCustom) private var settingsWidthCustom = SettingsContentWidth.customDefault
    @AppStorage(ClientPrefs.Key.workingVerbStyle) private var verbStyle = WorkingVerbStyle.classic.rawValue
    @AppStorage(ClientPrefs.Key.scrollbarVisibility) private var scrollbar = ScrollbarVisibility.system.rawValue
    @AppStorage(FontSmoothing.preferenceKey) private var fontSmoothing = FontSmoothing.system.rawValue
    @State private var smoothingAtLaunch = FontSmoothing.current().rawValue
    @Bindable private var workbench = AppEnvironment.shared.workbench
    @State private var themeFilter = ""

    var body: some View {
        SettingsForm {
            Section("主题") {
                // 当前主题的迷你工作台预览(侧栏、对话、代码块、输入框、终端)
                ThemeMiniWorkbench(package: appearance.themePackage)
                    .frame(height: 170)
                    .clipShape(RoundedRectangle(cornerRadius: OMMetrics.cardRadius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: OMMetrics.cardRadius, style: .continuous).strokeBorder(OMColors.hairline))
                    .accessibilityLabel(Text("主题预览"))

                HStack(spacing: 8) {
                    Image.om("search", size: 12).foregroundStyle(OMColors.tertiaryText)
                    TextField("快速筛选主题 (支持名称、深浅、风格…)", text: $themeFilter)
                        .textFieldStyle(.plain)
                        .font(OMFonts.small)
                    if !themeFilter.isEmpty {
                        Button { themeFilter = "" } label: {
                            Image.om("circle-x", size: 12).foregroundStyle(OMColors.tertiaryText)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: OMRadius.control).fill(OMColors.hoverFill))

                if themeFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ForEach(ThemeGroup.allCases.filter { $0 != .custom }, id: \.self) { group in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(group.title).font(OMFonts.small).foregroundStyle(OMColors.secondaryText)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 240), spacing: 8)], alignment: .leading, spacing: 8) {
                                ForEach(ThemePackage.all.filter { $0.group == group }) { package in
                                    ThemeCardPublic(package: package, selected: appearance.themeID == package.id) {
                                        appearance.themeID = package.id
                                    }
                                }
                            }
                        }
                    }
                } else {
                    let key = themeFilter.trimmingCharacters(in: .whitespacesAndNewlines)
                    let matched = ThemePackage.all.filter { package in
                        package.name.localizedCaseInsensitiveContains(key)
                            || package.group.title.localizedCaseInsensitiveContains(key)
                            || package.tone.displayName.localizedCaseInsensitiveContains(key)
                            || ThemePersonality.tagline(for: package).localizedCaseInsensitiveContains(key)
                    }
                    if matched.isEmpty {
                        Text("未找到与「\(themeFilter)」匹配的主题")
                            .font(OMFonts.small)
                            .foregroundStyle(OMColors.secondaryText)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 12)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 240), spacing: 8)], alignment: .leading, spacing: 8) {
                            ForEach(matched) { package in
                                ThemeCardPublic(package: package, selected: appearance.themeID == package.id) {
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
            if themeFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                CustomThemeSection()
            }
            Section("强调色") {
                AccentPicker(title: "主强调色", choice: $appearance.accent, hex: $appearance.customAccentHex)
                AccentPicker(title: "第二强调色", choice: $appearance.accent2, hex: $appearance.customAccent2Hex)
                AccentPreview().id(appearance.themeRevision)
                Note("主强调色用于按钮与选中态;第二强调色用于链接与次要徽标。「跟随主题」使用所选主题的默认配色。")
            }
            Section("聊天宽度") {
                SettingsSliderRow(
                    title: String(localized: "内容宽度"),
                    valueText: chatWidthSummary,
                    stops: ChatWidth.presets.map(\.displayName),
                    index: Binding(
                        get: { ChatWidth.presetIndex(raw: chatWidth, custom: chatWidthCustom) },
                        set: { chatWidth = ChatWidth.presets[min(max($0, 0), ChatWidth.presets.count - 1)].rawValue }
                    )
                )
                Note("控制会话时间线与输入框的最大宽度;窄屏或分屏时会自动收窄。")
            }
            Section("设置页宽度") {
                SettingsSliderRow(
                    title: String(localized: "内容宽度"),
                    valueText: settingsWidthSummary,
                    stops: SettingsContentWidth.presets.map(\.displayName),
                    index: Binding(
                        get: { SettingsContentWidth.presetIndex(raw: settingsWidth, custom: settingsWidthCustom) },
                        set: { settingsWidth = SettingsContentWidth.presets[min(max($0, 0), SettingsContentWidth.presets.count - 1)].rawValue }
                    )
                )
                Note("统一控制所有设置页右侧内容的最大宽度;窗口较窄时自动收窄。")
            }
            Section("字号") {
                SettingsSliderRow(
                    title: String(localized: "界面字号"),
                    valueText: "\(Int((appearance.uiFontScale * 100).rounded()))%",
                    stops: Self.fontStops(85...130),
                    index: fontIndex($appearance.uiFontScale, lower: 85)
                )
                SettingsSliderRow(
                    title: String(localized: "时间线字号"),
                    valueText: "\(Int((appearance.timelineFontScale * 100).rounded()))%",
                    stops: Self.fontStops(85...150),
                    index: fontIndex($appearance.timelineFontScale, lower: 85)
                )
                Text("预览:Claude 的回复会按这个大小显示。`let x = 1`").font(OMFonts.reading).padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(OMColors.card, in: RoundedRectangle(cornerRadius: OMRadius.control))
            }
            Section("字体平滑") {
                Picker("字体平滑", selection: $fontSmoothing) {
                    ForEach(FontSmoothing.allCases) { Text(LocalizedStringKey($0.title)).tag($0.rawValue) }
                }
                if fontSmoothing != smoothingAtLaunch {
                    HStack {
                        Note("字体平滑需要重新启动应用才会生效。")
                        Spacer()
                        Button("立即重启") { AppActions.shared.relaunch() }.buttonStyle(.omSecondary)
                    }
                }
                Note("控制文字笔画粗细(对应 macOS 的 AppleFontSmoothing,只影响本应用):「关闭」最细,「强」最粗;「跟随系统」沿用系统设置。")
            }
            Section("等待动画(Spinner Verbs)") {
                ForEach(WorkingVerbStyle.allCases) { style in
                    VerbStyleRow(style: style, selected: WorkingVerbStyle.resolve(verbStyle) == style) { verbStyle = style.rawValue }
                }
                Note("运行中会话流末尾的「✻ 思考中…」会按所选风格显示动词与动画字符;颜色跟随主题强调色。")
            }
            Section("滚动条") {
                Picker("显示方式", selection: $scrollbar) {
                    ForEach(ScrollbarVisibility.allCases) { Text(LocalizedStringKey($0.title)).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                Note("「跟随系统」沿用 macOS「显示滚动条」设置;「自动隐藏」仅在滚动时出现;「始终显示」常驻。")
            }
            Section("材质与动效") {
                Toggle("始终使用不透明材质", isOn: $appearance.alwaysOpaque)
                Toggle("低电量模式自动改用不透明材质", isOn: $appearance.fallbackOnLowPower)
                Toggle("减弱动效", isOn: $appearance.reduceMotion)
                Toggle("紧凑密度", isOn: $appearance.isCompact)
                Note("系统「减少透明度」「减少动态效果」始终优先。代码、Diff、编辑器等阅读区域恒为纯色,不受影响。")
            }
            layoutSection
            Section {
                Button("恢复默认主题") { appearance.reset(); chatWidth = ChatWidth.standard.rawValue; chatWidthCustom = ChatWidth.customDefault }
            }
        }
    }
}

extension AppearancePage {
    /// 聊天宽度当前值文案(档位名 + 点数)。
    fileprivate var chatWidthSummary: String {
        let width = ChatWidth(rawValue: chatWidth) ?? .standard
        let resolved = ChatWidth.resolve(raw: chatWidth, custom: chatWidthCustom)
        return width == .full ? width.displayName : "\(width.displayName) · \(Int(resolved)) pt"
    }

    /// 设置页宽度当前值文案(档位名 + 点数)。
    fileprivate var settingsWidthSummary: String {
        let width = SettingsContentWidth(rawValue: settingsWidth) ?? .standard
        let resolved = SettingsContentWidth.resolve(raw: settingsWidth, custom: settingsWidthCustom)
        return width == .full ? width.displayName : "\(width.displayName) · \(Int(resolved)) pt"
    }

    /// 字号档位文案:`85%`…(步长 5)。
    fileprivate static func fontStops(_ range: ClosedRange<Int>) -> [String] {
        stride(from: range.lowerBound, through: range.upperBound, by: 5).map { "\($0)%" }
    }

    /// 字号缩放(0.85…)与档位下标互转的绑定,步长 5%。
    fileprivate func fontIndex(_ scale: Binding<Double>, lower: Int) -> Binding<Int> {
        Binding(
            get: { max(0, (Int((scale.wrappedValue * 100).rounded()) - lower) / 5) },
            set: { scale.wrappedValue = Double(lower + $0 * 5) / 100 }
        )
    }

    /// 布局:迷你工作台示意图,拖动面板卡片到左栏/右栏/底部/编辑区(也可直接拖动面板标题条换位置)。
    @ViewBuilder
    fileprivate var layoutSection: some View {
        Section("布局") {
            LayoutDragEditor(workbench: workbench)
            Note("把「项目栏 / 文件 / Git / 终端 / 输出」的卡片拖到想要的位置;终端和输出的标题条也可以直接拖到窗口的左侧、右侧、底部或中间。换位置不会中断终端里正在运行的进程。")
            Button("恢复默认布局") { workbench.resetLayout() }
        }
    }
}

/// 等待动词风格行:风格名 + 示例动词 + 动画字符预览,选中时打勾。
private struct VerbStyleRow: View {
    let style: WorkingVerbStyle
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ActiveTimeline(interval: 0.15, start: Date(timeIntervalSince1970: 0)) { date in
                    Text(WorkingStatus.glyph(tick: Int(date.timeIntervalSinceReferenceDate / 0.15), style: style))
                        .font(OMFonts.body.weight(.medium))
                        .foregroundStyle(OMColors.accent)
                        .frame(width: 18)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(LocalizedStringKey(style.title)).font(OMFonts.body)
                    Text(LocalizedStringKey(style.summary)).font(OMFonts.caption).foregroundStyle(OMColors.secondaryText)
                }
                Spacer(minLength: 0)
                if selected { Image.om("check", size: 12).foregroundStyle(OMColors.accent) }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(selected ? OMColors.selectedFill : OMColors.subtleFill, in: RoundedRectangle(cornerRadius: OMMetrics.controlRadius, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// 主题卡片:迷你色板 + 名称,选中时描边。
struct ThemeCardPublic: View {
    let package: ThemePackage
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                ThemeMiniWorkbench(package: package)
                    .frame(height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: OMRadius.tag, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: OMRadius.tag, style: .continuous).strokeBorder(OMColors.hairline, lineWidth: 0.5))
                HStack(spacing: 4) {
                    Text(package.name).font(OMFonts.small).lineLimit(1)
                    Spacer(minLength: 0)
                    if selected { Image.om("check", size: 11).foregroundStyle(OMColors.accent) }
                }
            }
            .padding(6)
            .background(selected ? OMColors.selectedFill : Color.clear, in: RoundedRectangle(cornerRadius: OMRadius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: OMRadius.control, style: .continuous).strokeBorder(selected ? OMColors.accent : OMColors.hairline.opacity(0.6), lineWidth: selected ? 1.5 : 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(package.name)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .help("\(package.name) · \(ThemePersonality.tagline(for: package))")
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
                            if choice == item { Circle().strokeBorder(OMColors.primaryText, lineWidth: 2).padding(-3) }
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
            Text("主按钮").font(OMFonts.small).foregroundStyle(OMColors.onAction)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(OMColors.actionFill, in: OMPillShape())
            Text("链接示例").font(OMFonts.small).foregroundStyle(OMColors.accent2).underline()
            Tag("徽标", color: OMColors.accent2)
            Tag("新增", color: OMColors.diffAdded)
            Tag("删除", color: OMColors.danger)
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(OMColors.card, in: RoundedRectangle(cornerRadius: OMRadius.control))
    }
}
