// @author ixxxxoooo
// 设置页:编辑器、终端。

import AppKit
import ChatKit
import ClaudeConfigKit
import DesignSystem
import EditorKit
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
                SettingsRow("大文件模式起点", detail: "超过该行数的文件会强制换行并关闭复杂高亮以保持流畅(范围 2,000–200,000);新打开的文件立即生效。") {
                    TextField("", value: $largeFileLines, format: IntegerFormatStyle<Int>())
                        .multilineTextAlignment(.trailing).frame(width: 90).accessibilityLabel("大文件模式起点")
                    Text("行").font(OMFonts.small).foregroundStyle(OMColors.secondaryText)
                }
            }
            SettingsCard("Agent 联动") {
                SettingsToggleRow("跟随 Agent", detail: "Agent 每次修改文件都会在预览标签中打开该文件并跳到第一处改动(仅当前项目);本轮改动过的行会在行号栏用强调色标出。", isOn: $followAgent)
                Note("在编辑器里选中代码,右键「在对话中引用选区」或按 ⌘⇧L,会把 @文件:行范围 加入当前项目的输入框。").footnote()
            }
            SettingsCard("预览") {
                Text(verbatim: "func greet(name: String) -> String {\n    return \"Hello, \\(name)\"\n}")
                    .font(Font(previewFont))
                    .lineSpacing(EditorFontPrefs.lineSpacing(for: previewFont))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Note("编辑器用于查看 Agent 改动的文件;保存时处理(去尾随空白等)将在编辑能力开放后提供。")
        }
        .onAppear {
            let current = EditorFontPrefs.normalizedFamily(fontFamily)
            customFamily = current == EditorFontPrefs.systemMonospace ? "" : current
        }
    }
}

/// 终端。
struct TerminalPage: View {
    @AppStorage(ClientPrefs.Key.terminalFontSize) private var fontSize = 12.0
    @AppStorage(ClientPrefs.Key.terminalOutputKB) private var outputKB = 1024
    @AppStorage(ClientPrefs.Key.terminalInheritEnv) private var inheritEnv = true
    @AppStorage(ClientPrefs.Key.featureTerminal) private var terminalCapability = false

    var body: some View {
        SettingsScroll {
            SettingsCard("Agent 终端") {
                SettingsToggleRow("让 Agent 使用 OhMyAgent 的终端", detail: "声明 terminal 能力:开启后 Claude 的命令会在客户端终端里运行并实时显示输出;对已打开的窗口在重新连接后生效。关闭时由 claude 自己执行命令。", isOn: $terminalCapability)
                SettingsRow(String(localized: "输出字号 \(String(format: "%.1f", fontSize)) pt")) {
                    Slider(value: $fontSize, in: 9...20, step: 0.5).frame(width: 220)
                }
                SettingsRow("输出缓冲上限", detail: "超出上限时丢弃最早的输出(在字符边界截断)。范围 64–16,384 KB。") {
                    TextField("", value: $outputKB, format: IntegerFormatStyle<Int>())
                        .multilineTextAlignment(.trailing).frame(width: 90).accessibilityLabel("输出缓冲上限")
                    Text("KB").font(OMFonts.small).foregroundStyle(OMColors.secondaryText)
                }
                SettingsToggleRow("继承完整的登录 Shell 环境变量", detail: "关闭后只保留 PATH、HOME、USER、SHELL、LANG、TERM 等基础变量,可避免把令牌等敏感变量暴露给命令。", isOn: $inheritEnv)
            }
        }
    }
}
