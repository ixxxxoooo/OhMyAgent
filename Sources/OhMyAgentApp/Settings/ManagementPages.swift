// @author ygw
// 设置页:编辑器、终端。

import ChatKit
import ClaudeConfigKit
import DesignSystem
import SwiftUI

/// 编辑器。
struct EditorPage: View {
    @AppStorage(ClientPrefs.Key.editorFontSize) private var fontSize = 12.5
    @AppStorage(ClientPrefs.Key.editorWrap) private var wrap = true
    @AppStorage(ClientPrefs.Key.editorLargeFileLines) private var largeFileLines = 20_000
    @AppStorage(ClientPrefs.Key.editorLSP) private var lspEnabled = true

    var body: some View {
        SettingsForm {
            Section("文件查看器") {
                LabeledContent("字号 \(String(format: "%.1f", fontSize)) pt") {
                    Slider(value: $fontSize, in: 9...28, step: 0.5).frame(width: 220)
                }
                Toggle("自动换行", isOn: $wrap)
                LabeledContent("大文件模式起点(行)") {
                    TextField("", value: $largeFileLines, format: .number).frame(width: 100).multilineTextAlignment(.trailing)
                }
                Note("超过该行数的文件会强制换行并关闭复杂高亮以保持流畅(范围 2,000–200,000)。新打开的文件立即生效。")
            }
            Section("语言服务器(LSP)") {
                Toggle("启用诊断、悬停提示、跳转定义与补全", isOn: $lspEnabled)
                Note("Swift 使用 Xcode 自带的 sourcekit-lsp;TypeScript/JavaScript 需要 typescript-language-server,Python 需要 pyright(npm i -g typescript-language-server typescript pyright)。悬停停留查看类型,⌘ 点击或 F12 跳转定义,⌃Space 补全,输入 . 自动补全。")
            }
            Section("预览") {
                Text("func greet(name: String) -> String {\n    return \"Hello, \\(name)\"\n}")
                    .font(.system(size: fontSize, design: .monospaced))
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(OMColors.surface, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(OMColors.hairline))
            }
            Section {
                Note("编辑器用于查看 Agent 改动的文件;保存时处理(去尾随空白等)将在编辑能力开放后提供。")
            }
        }
    }
}

/// 终端。
struct TerminalPage: View {
    @AppStorage(ClientPrefs.Key.terminalFontSize) private var fontSize = 11.5
    @AppStorage(ClientPrefs.Key.terminalOutputKB) private var outputKB = 1024
    @AppStorage(ClientPrefs.Key.terminalInheritEnv) private var inheritEnv = true
    @AppStorage(ClientPrefs.Key.featureTerminal) private var terminalCapability = false

    var body: some View {
        SettingsForm {
            Section("Agent 终端") {
                Toggle("让 Agent 使用 OhMyAgent 的终端(声明 terminal 能力)", isOn: $terminalCapability)
                Note("开启后 Claude 的命令会在客户端终端里运行并实时显示输出;对已打开的窗口在重新连接后生效。关闭时由 claude 自己执行命令。")
                LabeledContent("输出字号 \(String(format: "%.1f", fontSize)) pt") {
                    Slider(value: $fontSize, in: 9...20, step: 0.5).frame(width: 220)
                }
                LabeledContent("输出缓冲上限(KB)") {
                    TextField("", value: $outputKB, format: .number).frame(width: 100).multilineTextAlignment(.trailing)
                }
                Note("超出上限时丢弃最早的输出(在字符边界截断)。范围 64–16,384 KB。")
                Toggle("继承完整的登录 Shell 环境变量", isOn: $inheritEnv)
                Note("关闭后只保留 PATH、HOME、USER、SHELL、LANG、TERM 等基础变量,可避免把令牌等敏感变量暴露给命令。")
            }
        }
    }
}
