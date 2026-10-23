// @author ixxxxoooo
// 编辑器引擎开关:旧 TextKit 2 引擎(`textkit`)与新的原生自绘引擎(`native2`)。
// 默认原生引擎(native2,已通过全部基准与测试)。旧 TextKit 引擎只保留两处用途:Markdown 文件的就地渲染(`MarkdownLive`),
// 以及排障时用环境变量 `OMA_EDITOR_ENGINE=textkit`(或偏好 `editor.engine`)强制回退对照;环境变量优先于偏好。

import Foundation

/// 编辑器引擎种类。
public enum EditorEngineKind: String, Sendable, CaseIterable {
    /// 旧引擎:NSTextView + TextKit 2。
    case textkit
    /// 新引擎:EditorCore 文本绳 + 自绘视图。
    case native2
}

public enum EditorEngine {
    /// 偏好键(UserDefaults)。
    public static let defaultsKey = "editor.engine"
    /// 默认引擎。
    public static let defaultKind: EditorEngineKind = .native2

    /// 当前引擎:环境变量 > 偏好 > 默认。
    public static var current: EditorEngineKind {
        if let raw = ProcessInfo.processInfo.environment["OMA_EDITOR_ENGINE"], let kind = EditorEngineKind(rawValue: raw) { return kind }
        if let raw = UserDefaults.standard.string(forKey: defaultsKey), let kind = EditorEngineKind(rawValue: raw) { return kind }
        return defaultKind
    }

    /// 某语言的文件是否使用原生引擎:Markdown 仍走 TextKit(就地渲染 `MarkdownLive` 依赖 NSTextView 的属性文本)。
    /// - Parameter language: 文件语言
    /// - Returns: true 表示用 `NativeCodeEditor`
    public static func usesNative(for language: SyntaxLanguage) -> Bool {
        current == .native2 && language != .markdown
    }
}
