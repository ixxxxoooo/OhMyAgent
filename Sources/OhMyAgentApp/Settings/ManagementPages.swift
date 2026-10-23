// @author ixxxxoooo
// 设置页:编辑器、终端。

import AgentHost
import AppKit
import ChatKit
import ClaudeConfigKit
import DesignSystem
import EditorKit
import IDEKit
import SwiftUI

/// 编辑器。
struct EditorPage: View {
    @AppStorage(ClientPrefs.Key.editorFontSize) private var fontSize = Double(EditorFontPrefs.defaultSize)
    @AppStorage(ClientPrefs.Key.editorFontFamily) private var fontFamily = EditorFontPrefs.systemMonospace
    /// 自定义字体输入框的草稿,回车或失焦时提交
    @State private var customFamily = ""
    @AppStorage(ClientPrefs.Key.editorWrap) private var wrap = true
    @AppStorage(ClientPrefs.Key.editorLargeFileLines) private var largeFileLines = 20_000
    @AppStorage(ClientPrefs.Key.editorFollowAgent) private var followAgent = false
    @AppStorage(EditorBehaviorPrefs.autoCloseKey) private var autoClose = true
    @AppStorage(EditorBehaviorPrefs.currentLineKey) private var currentLine = true
    @AppStorage(EditorBehaviorPrefs.bracketMatchKey) private var bracketMatch = true
    @AppStorage(EditorBehaviorPrefs.stickyScrollKey) private var stickyScroll = true
    @AppStorage(IDEAutoSaveMode.key) private var autoSave = IDEAutoSaveMode.off.rawValue
    private let appearance = AppearanceModel.shared
    @State private var schemePickerShown = false

    /// 下拉选项:系统等宽 + 本机已安装的预置字体;当前值若不在其中(自定义字体)也要列出,否则选择器显示为空。
    private var fontOptions: [(value: String, title: String)] {
        let current = EditorFontPrefs.normalizedFamily(fontFamily)
        var options = EditorFontPrefs.presets
            .filter { EditorFontPrefs.isInstalled($0.value) }
            .map { (value: $0.value, title: "\($0.value) · \(omLocalized($0.note))") }
        if !options.contains(where: { $0.value == current }) { options.append((value: current, title: current)) }
        return options
    }

    /// 预览用字体(与编辑器同一套解析与回退)。
    private var previewFont: NSFont {
        EditorFontPrefs.font(family: fontFamily, size: EditorFontPrefs.clampedSize(fontSize))
    }

    /// 预览代码(覆盖关键字、字符串、注释、数字、类型、函数与属性)。
    private static let previewSample = """
    // Greets a person
    struct Greeter {
        let name: String
        func greet(times: Int = 3) -> String {
            let text = "Hello, \\(name)"
            return String(repeating: text, count: times)
        }
    }
    """

    /// 当前主题是否深色(决定自定义写入浅色还是深色变体)。
    private var isDarkTheme: Bool { ThemeRuntime.palette?.isDark ?? ThemeRuntime.systemIsDark }

    /// 当前方案的显示名。
    private var schemeName: String {
        SyntaxScheme.find(appearance.syntaxSchemeID)?.name ?? String(localized: "跟随主题")
    }

    /// 方案下拉的条目。
    private var schemeEntries: [PickEntry] {
        [PickEntry(id: SyntaxScheme.followThemeID, title: String(localized: "跟随主题"), subtitle: String(localized: "使用当前界面主题自带的语法色"))]
            + SyntaxScheme.all.map { PickEntry(id: $0.id, title: $0.name) }
    }

    /// 某个语法项的取色绑定:读取当前生效色,写入则记为当前明暗下的自定义。
    private func colorBinding(_ token: SyntaxToken) -> Binding<Color> {
        Binding(
            get: { Color(nsColor: EditorTheme.syntaxColor(token)) },
            set: { newValue in
                guard let srgb = NSColor(newValue).usingColorSpace(.sRGB) else { return }
                let hex = ThemeRGB(red: srgb.redComponent, green: srgb.greenComponent, blue: srgb.blueComponent).hexString
                appearance.syntaxOverrides[SyntaxPrefs.overrideKey(token, dark: isDarkTheme)] = hex
            }
        )
    }

    /// 代码高亮配色卡片:方案选择 + 逐项自定义。
    private var syntaxCard: some View {
        SettingsCard("代码高亮") {
            SettingsRow("配色方案", detail: "编辑器与聊天里的代码块使用同一套配色。默认跟随当前界面主题;也可以指定独立的方案,浅色/深色主题会自动取对应变体。") {
                Button { schemePickerShown.toggle() } label: {
                    HStack(spacing: 6) {
                        Text(verbatim: schemeName)
                        Image.om("chevron-down", size: 12)
                    }
                }
                .buttonStyle(.omSecondary)
                .omPicker(isPresented: $schemePickerShown, entries: schemeEntries, selectedID: appearance.syntaxSchemeID,
                          placeholder: String(localized: "搜索配色"), placement: .below, width: 240, showsSearch: false) { entry in
                    appearance.syntaxSchemeID = entry.id
                }
            }
            ForEach(SyntaxToken.allCases) { token in
                SettingsRow(token.title) {
                    if appearance.syntaxOverrides[SyntaxPrefs.overrideKey(token, dark: isDarkTheme)] != nil {
                        Button { appearance.syntaxOverrides[SyntaxPrefs.overrideKey(token, dark: isDarkTheme)] = nil } label: {
                            Image.om("undo-2", size: 12)
                        }
                        .buttonStyle(.omIcon)
                        .omTooltip(String(localized: "恢复为方案颜色"))
                        .accessibilityLabel("恢复为方案颜色")
                    }
                    ColorPicker("", selection: colorBinding(token), supportsOpacity: false).labelsHidden()
                }
            }
            SettingsRow("恢复默认", detail: "清除全部自定义颜色并回到「跟随主题」。") {
                Button("恢复默认") {
                    appearance.syntaxOverrides = [:]
                    appearance.syntaxSchemeID = SyntaxScheme.followThemeID
                }
                .buttonStyle(.omSecondary)
                .disabled(appearance.syntaxOverrides.isEmpty && appearance.syntaxSchemeID == SyntaxScheme.followThemeID)
            }
            Note(isDarkTheme
                 ? String(localized: "自定义颜色分别记在浅色与深色两个变体里:当前是深色主题,改的是深色变体。")
                 : String(localized: "自定义颜色分别记在浅色与深色两个变体里:当前是浅色主题,改的是浅色变体。")).footnote()
        }
    }

    /// 提交自定义字体:空串恢复系统等宽,否则写入规整后的字体族名。
    private func commitCustomFamily() {
        fontFamily = EditorFontPrefs.normalizedFamily(customFamily)
        customFamily = fontFamily == EditorFontPrefs.systemMonospace ? "" : fontFamily
    }

    var body: some View {
        SettingsScroll {
            SettingsCard("文件查看器") {
                SettingsRow("代码字体", detail: "下拉里只列出本机已安装的预置字体;字体未安装时自动回退到系统等宽。") {
                    Picker("", selection: Binding(
                        get: { EditorFontPrefs.normalizedFamily(fontFamily) },
                        set: { fontFamily = $0; customFamily = $0 == EditorFontPrefs.systemMonospace ? "" : $0 }
                    )) {
                        ForEach(fontOptions, id: \.value) { option in
                            Text(option.title).tag(option.value)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                SettingsRow("自定义字体", detail: "手动填写任意已安装的字体族名,回车生效,留空恢复系统等宽。") {
                    TextField("", text: $customFamily, prompt: Text(verbatim: EditorFontPrefs.systemMonospace))
                        .frame(width: 220)
                        .multilineTextAlignment(.trailing)
                        .onSubmit(commitCustomFamily)
                }
                SettingsRow(String(localized: "字号 \(Int(EditorFontPrefs.clampedSize(fontSize))) pt")) {
                    Slider(value: $fontSize, in: EditorFontPrefs.sizeRange, step: 1).frame(width: 220)
                }
                SettingsToggleRow("自动换行", isOn: $wrap)
                SettingsRow("大文件模式起点", detail: "超过该行数的文件只高亮视口附近以保持流畅(范围 2,000–200,000);新打开的文件立即生效。") {
                    TextField("", value: $largeFileLines, format: IntegerFormatStyle<Int>())
                        .multilineTextAlignment(.trailing).frame(width: 90).accessibilityLabel("大文件模式起点")
                    Text("行").font(OMFonts.small).foregroundStyle(OMColors.secondaryText)
                }
            }
            SettingsCard("代码编辑") {
                SettingsToggleRow("自动闭合括号与引号", detail: "输入 ( [ { \" ' ` 时补全另一半,选中文本时输入会包裹选区。", isOn: $autoClose)
                SettingsToggleRow("高亮当前行", isOn: $currentLine)
                SettingsToggleRow("高亮配对括号", isOn: $bracketMatch)
                SettingsToggleRow("粘性滚动", detail: "IDE 窗口的编辑器顶部固定显示当前所在的外层代码块标题(最多 3 行),点击跳转。", isOn: $stickyScroll)
                SettingsRow("自动保存", detail: "IDE 窗口里的文件修改后自动写盘;「失焦」指窗口失去键盘焦点时保存。") {
                    Picker("", selection: $autoSave) {
                        Text("关闭").tag(IDEAutoSaveMode.off.rawValue)
                        Text("延迟").tag(IDEAutoSaveMode.afterDelay.rawValue)
                        Text("失焦").tag(IDEAutoSaveMode.onFocusLoss.rawValue)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 180)
                }
                Note("快捷键:⌘/ 切换注释、⌥↑/⌥↓ 移动行、⇧⌥↑/⇧⌥↓ 复制行、⌘⇧K 删除行、⌘D 添加下一个相同项、⌥ 点击添加光标、⌃G 转到行。").footnote()
            }
            SettingsCard("Agent 联动") {
                SettingsToggleRow("跟随 Agent", detail: "Agent 每次修改文件都会在预览标签中打开该文件并跳到第一处改动(仅当前项目);本轮改动过的行会在行号栏用强调色标出。", isOn: $followAgent)
                Note("在编辑器里选中代码,右键「在对话中引用选区」或按 ⌘⇧L,会把 @文件:行范围 加入当前项目的输入框。").footnote()
            }
            syntaxCard
            SettingsCard("预览") {
                // 预览走与编辑器、聊天代码块相同的高亮与配色;读取 renderKey 让配色变化时立即刷新
                let _ = appearance.renderKey
                Text(CodeHighlighter.attributed(Self.previewSample, language: .swift))
                    .font(Font(previewFont))
                    .foregroundStyle(Color(nsColor: EditorTheme.default.foreground))
                    .lineSpacing(EditorFontPrefs.lineSpacing(for: previewFont))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color(nsColor: EditorTheme.default.background), in: RoundedRectangle(cornerRadius: OMRadius.card, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: OMRadius.card, style: .continuous).strokeBorder(OMColors.hairline, lineWidth: 0.5))
            }
            Note("编辑器用于查看 Agent 改动的文件;保存时处理(去尾随空白等)将在编辑能力开放后提供。")
        }
        .onAppear {
            let current = EditorFontPrefs.normalizedFamily(fontFamily)
            customFamily = current == EditorFontPrefs.systemMonospace ? "" : current
        }
    }
}

/// 终端:交互终端的外观/光标与键盘/Shell,以及 Agent 终端(声明 terminal 能力后命令在客户端终端运行)。
struct TerminalPage: View {
    // Agent 终端
    @AppStorage(ClientPrefs.Key.terminalFontSize) private var outputFontSize = 12.0
    @AppStorage(ClientPrefs.Key.terminalOutputKB) private var outputKB = 1024
    @AppStorage(ClientPrefs.Key.terminalInheritEnv) private var inheritEnv = true
    @AppStorage(ClientPrefs.Key.featureTerminal) private var terminalCapability = false
    @AppStorage(ClientPrefs.Key.featureAgentTerminalOutput) private var agentTerminalOutput = true
    @AppStorage(ClientPrefs.Key.terminalSandbox) private var sandboxEnabled = false
    @AppStorage(ClientPrefs.Key.terminalSandboxNetwork) private var sandboxNetwork = TerminalSandboxConfig.Network.local.rawValue
    // 交互终端
    @AppStorage(ClientPrefs.Key.terminalShellFontFamily) private var fontFamily = EditorFontPrefs.systemMonospace
    @AppStorage(ClientPrefs.Key.terminalShellFontSize) private var fontSize = TerminalPrefs.defaultSize
    @AppStorage(ClientPrefs.Key.terminalCursorShape) private var cursorShape = TerminalCursorShape.block.rawValue
    @AppStorage(ClientPrefs.Key.terminalCursorBlink) private var cursorBlink = true
    @AppStorage(ClientPrefs.Key.terminalScrollback) private var scrollback = TerminalPrefs.defaultScrollback
    @AppStorage(ClientPrefs.Key.terminalOptionAsMeta) private var optionAsMeta = true
    @AppStorage(ClientPrefs.Key.terminalShellPath) private var shellPath = ""
    @AppStorage(ClientPrefs.Key.terminalLoginShell) private var loginShell = true
    @AppStorage(ClientPrefs.Key.terminalStartDirectory) private var startDirectory = TerminalStartDirectory.project.rawValue

    /// 字号档位(pt)
    private static let sizeStops: [Double] = [9, 10, 11, 12, 13, 14, 16, 18, 20, 24]

    /// 字体下拉:预置中本机已安装的 + 当前值(自定义)。
    private var fontOptions: [(value: String, title: String)] {
        let current = EditorFontPrefs.normalizedFamily(fontFamily)
        var options = EditorFontPrefs.presets
            .filter { EditorFontPrefs.isInstalled($0.value) }
            .map { (value: $0.value, title: "\($0.value) · \(omLocalized($0.note))") }
        if !options.contains(where: { $0.value == current }) { options.append((value: current, title: current)) }
        return options
    }

    private var sizeIndex: Binding<Int> {
        Binding(
            get: {
                let clamped = TerminalPrefs.clampedSize(fontSize)
                return Self.sizeStops.enumerated().min { abs($0.element - clamped) < abs($1.element - clamped) }?.offset ?? 3
            },
            set: { fontSize = Self.sizeStops[min(max($0, 0), Self.sizeStops.count - 1)] }
        )
    }

    /// 当前偏好快照(预览与默认 Shell 提示用)。
    private var prefs: TerminalPrefs { TerminalPrefs.load() }

    var body: some View {
        SettingsScroll {
            appearanceCard
            behaviorCard
            shellCard
            agentCard
            sandboxCard
            ToolApprovalCard(domain: .terminal)
            TerminalPromptHintCard()
        }
    }

    private var appearanceCard: some View {
        SettingsCard("外观") {
            SettingsRow("字体", detail: "下拉里只列出本机已安装的预置字体;未安装时自动回退到系统等宽。修改立即作用于所有已打开的终端。") {
                Picker("", selection: Binding(get: { EditorFontPrefs.normalizedFamily(fontFamily) }, set: { fontFamily = $0 })) {
                    ForEach(fontOptions, id: \.value) { option in Text(option.title).tag(option.value) }
                }
                .labelsHidden()
                .fixedSize()
            }
            SettingsSliderRow(
                title: String(localized: "字号"),
                valueText: "\(Int(TerminalPrefs.clampedSize(fontSize))) pt",
                stops: Self.sizeStops.map { String(Int($0)) },
                index: sizeIndex
            )
            terminalPreview
            SettingsRow("光标形状", detail: "应用程序(如 vim)也可以临时改变光标形状。") {
                OMCompactSegmented(
                    options: TerminalCursorShape.allCases.map { ($0.rawValue, $0.title) },
                    selection: $cursorShape, accessibilityName: String(localized: "光标形状"))
            }
            SettingsToggleRow("光标闪烁", isOn: $cursorBlink)
        }
    }

    /// 字体预览:用终端自己的前景/背景与字体。
    private var terminalPreview: some View {
        Text(verbatim: "$ git status\nOn branch main — nothing to commit ✓")
            .font(Font(prefs.font))
            .foregroundStyle(Color(nsColor: OMTerminalPalette.foreground))
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: OMTerminalPalette.background), in: RoundedRectangle(cornerRadius: OMRadius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: OMRadius.control, style: .continuous).stroke(OMColors.hairline))
    }

    private var behaviorCard: some View {
        SettingsCard("行为") {
            SettingsToggleRow("Option 键作为 Meta", detail: "开启后 ⌥ 组合键发送 ESC 前缀(Emacs / readline 的 ⌥F、⌥B 等);关闭后 ⌥ 用于输入特殊字符。", isOn: $optionAsMeta)
            SettingsNumericField(title: "回滚行数", value: $scrollback, format: IntegerFormatStyle<Int>(), unit: "行")
            Note("范围 500–100,000 行,默认 5,000。回滚行数只对新打开的终端生效,行数越多占用内存越大。").footnote()
        }
    }

    private var shellCard: some View {
        SettingsCard("Shell") {
            SettingsRow("Shell 程序", detail: String(localized: "留空使用系统默认 Shell(\(prefs.resolvedShell()));填写可执行文件路径(如 /opt/homebrew/bin/fish)后,新打开的终端使用它。")) {
                TextField("", text: $shellPath, prompt: Text(verbatim: "$SHELL"))
                    .frame(width: 220)
                    .multilineTextAlignment(.trailing)
                    .accessibilityLabel("Shell 程序")
            }
            SettingsToggleRow("作为登录 Shell 启动", detail: "加载 ~/.zprofile 等登录配置,使 PATH 与终端应用里一致;对新打开的终端生效。", isOn: $loginShell)
            SettingsRow("新终端起始目录", detail: "「项目根目录」为当前选中项目的目录;没有项目时使用主目录。") {
                OMCompactSegmented(
                    options: TerminalStartDirectory.allCases.map { ($0.rawValue, $0.title) },
                    selection: $startDirectory, accessibilityName: String(localized: "新终端起始目录"))
            }
        }
    }

    /// Agent 终端沙箱:限制写权限(仅工作区与临时目录)与网络。
    private var sandboxCard: some View {
        SettingsCard("沙箱") {
            SettingsToggleRow("在沙箱中运行 Agent 命令", detail: "用 macOS sandbox-exec 限制命令只能写入工作区与临时目录;被拦截时工具卡片提供「放行一次并重试」。仅对 Agent 终端生效(需开启上方「让 Agent 使用 OhMyAgent 的终端」)。可在工作区 .oma/sandbox.json 里调整 network 与 additionalWritablePaths。", isOn: $sandboxEnabled)
            if sandboxEnabled {
                SettingsRow("网络", detail: "完全禁止、仅本机回环或不限制。") {
                    OMCompactSegmented(
                        options: TerminalSandboxConfig.Network.allCases.map { ($0.rawValue, networkTitle($0)) },
                        selection: $sandboxNetwork, accessibilityName: String(localized: "沙箱网络"))
                }
                if !TerminalSandbox.isAvailable { Note("未找到 /usr/bin/sandbox-exec,沙箱不会生效。") }
            }
        }
    }

    private func networkTitle(_ network: TerminalSandboxConfig.Network) -> String {
        switch network {
        case .off: String(localized: "禁止")
        case .local: String(localized: "仅本机")
        case .all: String(localized: "不限制")
        }
    }

    private var agentCard: some View {
        SettingsCard("Agent 终端") {
            SettingsToggleRow("让 Agent 使用 OhMyAgent 的终端", detail: "声明 terminal 能力:开启后 Claude 的命令会在客户端终端里运行并实时显示输出;对已打开的窗口在重新连接后生效。关闭时由 claude 自己执行命令。", isOn: $terminalCapability)
            SettingsToggleRow("显示 Agent 自己执行的命令输出", detail: "声明 _meta.terminal_output:Claude 自己执行的命令(含后台命令)会作为终端显示,后台命令可在终端面板里实时查看;对已打开的窗口在重新连接后生效。", isOn: $agentTerminalOutput)
            SettingsRow(String(localized: "输出字号 \(String(format: "%.1f", outputFontSize)) pt"), detail: "会话里命令输出的字号。") {
                Slider(value: $outputFontSize, in: 9...20, step: 0.5).frame(width: 220)
            }
            SettingsNumericField(title: "输出缓冲上限", value: $outputKB, format: IntegerFormatStyle<Int>(), unit: "KB")
            Note("超出上限时丢弃最早的输出(在字符边界截断)。范围 64–16,384 KB。").footnote()
            SettingsToggleRow("继承完整的登录 Shell 环境变量", detail: "关闭后只保留 PATH、HOME、USER、SHELL、LANG、TERM 等基础变量,可避免把令牌等敏感变量暴露给命令。", isOn: $inheritEnv)
        }
    }
}
