// @author ixxxxoooo
// 编辑器引擎开关:旧 TextKit 2 引擎(`textkit`)与新的原生自绘引擎(`native2`)。
// 迁移期默认旧引擎;全部基准与测试通过后在最后一次提交里改默认。环境变量 `OMA_EDITOR_ENGINE` 优先于偏好,便于脚本对照。

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
    /// 迁移完成后的默认引擎。
    public static let defaultKind: EditorEngineKind = .textkit

    /// 当前引擎:环境变量 > 偏好 > 默认。
    public static var current: EditorEngineKind {
        if let raw = ProcessInfo.processInfo.environment["OMA_EDITOR_ENGINE"], let kind = EditorEngineKind(rawValue: raw) { return kind }
        if let raw = UserDefaults.standard.string(forKey: defaultsKey), let kind = EditorEngineKind(rawValue: raw) { return kind }
        return defaultKind
    }
}
