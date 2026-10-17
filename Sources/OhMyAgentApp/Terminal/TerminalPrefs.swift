// @author ixxxxoooo
// 交互终端偏好:字体、光标、回滚、Option 键、Shell 与起始目录。
// 纯值类型 + 注入 UserDefaults,便于测试;`TerminalController` 在创建时读取、在偏好变化时热更新。

import AppKit
import ChatKit
import EditorKit
import Foundation
import SwiftTerm

/// 光标形状。
enum TerminalCursorShape: String, CaseIterable, Sendable {
    case block, bar, underline

    /// 设置页显示名(中文原文,经本地化取译文)。
    var title: String {
        switch self {
        case .block: return "方块"
        case .bar: return "竖线"
        case .underline: return "下划线"
        }
    }
}

/// 新终端的起始目录策略。
enum TerminalStartDirectory: String, CaseIterable, Sendable {
    /// 当前项目根目录
    case project
    /// 用户主目录
    case home

    /// 设置页显示名。
    var title: String { self == .project ? "项目根目录" : "主目录" }
}

/// 交互终端偏好快照(字体解析依赖主线程的字体管理器,整体隔离到主线程)。
@MainActor
struct TerminalPrefs: Equatable, Sendable {
    /// 字号范围(pt)
    static let sizeRange: ClosedRange<Double> = 9...24
    /// 回滚行数范围
    static let scrollbackRange: ClosedRange<Int> = 500...100_000
    /// 默认值
    static let defaultSize = 12.0
    static let defaultScrollback = 5_000

    var fontFamily: String = EditorFontPrefs.systemMonospace
    var fontSize: Double = defaultSize
    var cursorShape: TerminalCursorShape = .block
    var cursorBlink = true
    var scrollback = defaultScrollback
    var optionAsMeta = true
    /// 自定义 Shell 可执行文件路径;空串表示使用 `$SHELL`
    var shellPath = ""
    var loginShell = true
    var startDirectory: TerminalStartDirectory = .project

    /// 从 UserDefaults 读取并夹取到合法范围。
    /// - Parameter defaults: 偏好存储
    /// - Returns: 偏好快照
    static func load(_ defaults: UserDefaults = .standard) -> TerminalPrefs {
        var prefs = TerminalPrefs()
        prefs.fontFamily = EditorFontPrefs.normalizedFamily(defaults.string(forKey: ClientPrefs.Key.terminalShellFontFamily))
        prefs.fontSize = clampedSize(defaults.object(forKey: ClientPrefs.Key.terminalShellFontSize) as? Double)
        prefs.cursorShape = defaults.string(forKey: ClientPrefs.Key.terminalCursorShape).flatMap(TerminalCursorShape.init(rawValue:)) ?? .block
        prefs.cursorBlink = defaults.object(forKey: ClientPrefs.Key.terminalCursorBlink) as? Bool ?? true
        prefs.scrollback = clampedScrollback(defaults.object(forKey: ClientPrefs.Key.terminalScrollback) as? Int)
        prefs.optionAsMeta = defaults.object(forKey: ClientPrefs.Key.terminalOptionAsMeta) as? Bool ?? true
        prefs.shellPath = (defaults.string(forKey: ClientPrefs.Key.terminalShellPath) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        prefs.loginShell = defaults.object(forKey: ClientPrefs.Key.terminalLoginShell) as? Bool ?? true
        prefs.startDirectory = defaults.string(forKey: ClientPrefs.Key.terminalStartDirectory).flatMap(TerminalStartDirectory.init(rawValue:)) ?? .project
        return prefs
    }

    /// 字号夹取(未设置/非法值回到默认)。
    static func clampedSize(_ raw: Double?) -> Double {
        guard let raw, raw.isFinite else { return defaultSize }
        return min(max(raw, sizeRange.lowerBound), sizeRange.upperBound)
    }

    /// 回滚行数夹取。
    static func clampedScrollback(_ raw: Int?) -> Int {
        guard let raw else { return defaultScrollback }
        return min(max(raw, scrollbackRange.lowerBound), scrollbackRange.upperBound)
    }

    /// 终端字体:按字体族解析(未安装回退系统等宽),再套用终端字号。
    var font: NSFont {
        let base = EditorFontPrefs.font(family: fontFamily, size: CGFloat(Self.defaultSize))
        return NSFont(descriptor: base.fontDescriptor, size: CGFloat(fontSize)) ?? NSFont.monospacedSystemFont(ofSize: CGFloat(fontSize), weight: .regular)
    }

    /// SwiftTerm 光标样式。
    var cursorStyle: CursorStyle {
        switch (cursorShape, cursorBlink) {
        case (.block, true): return .blinkBlock
        case (.block, false): return .steadyBlock
        case (.bar, true): return .blinkBar
        case (.bar, false): return .steadyBar
        case (.underline, true): return .blinkUnderline
        case (.underline, false): return .steadyUnderline
        }
    }

    /// 实际使用的 Shell:自定义路径可执行则用之,否则 `$SHELL`,再缺省 `/bin/zsh`。
    /// - Parameter environment: 环境变量(测试可注入)
    func resolvedShell(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if !shellPath.isEmpty, FileManager.default.isExecutableFile(atPath: (shellPath as NSString).expandingTildeInPath) {
            return (shellPath as NSString).expandingTildeInPath
        }
        if let shell = environment["SHELL"], !shell.isEmpty { return shell }
        return "/bin/zsh"
    }

    /// Shell 启动参数:登录 Shell 加载用户 profile。
    var shellArguments: [String] { loginShell ? ["-l"] : [] }

    /// 新终端的起始目录。
    /// - Parameter project: 当前项目根目录(无项目时为 nil)
    func startDirectoryPath(project: String?) -> String {
        switch startDirectory {
        case .home: return NSHomeDirectory()
        case .project: return project.flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
        }
    }
}
