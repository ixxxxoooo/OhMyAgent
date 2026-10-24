// @author ixxxxoooo
// 编辑器共用的轻量类型:诊断、签名帮助、编辑动作、光标状态、行标记。
// 原先散落在旧 TextKit 引擎的文件里(`EditorLanguage`/`CodeEditor`/`CodeEditorView`),旧引擎删除前先集中到这里。

import AppKit

/// 编辑器内的一条诊断。偏移单位为 UTF-16(与 NSRange 一致)。
public struct EditorDiagnostic: Sendable, Equatable {
    public enum Severity: Int, Sendable, Equatable {
        case error = 1, warning, information, hint
    }

    public var range: NSRange
    public var severity: Severity
    public var message: String

    /// - Parameters:
    ///   - range: 受影响的文本范围
    ///   - severity: 严重程度
    ///   - message: 诊断文案
    public init(range: NSRange, severity: Severity, message: String) {
        self.range = range
        self.severity = severity
        self.message = message
    }
}

/// 签名帮助:函数签名文本与当前参数的范围。
public struct EditorSignature: Sendable, Equatable {
    /// 完整签名,如 `f(a: Int, b: String)`
    public var label: String
    /// 当前参数在 `label` 里的 UTF-16 范围
    public var activeParameter: NSRange?

    public init(label: String, activeParameter: NSRange? = nil) {
        self.label = label
        self.activeParameter = activeParameter
    }
}

/// 编辑器可被外部(命令面板、菜单)触发的编辑动作。
public enum EditorAction: Sendable {
    case toggleComment, deleteLine, moveLineUp, moveLineDown, duplicateLineUp, duplicateLineDown, addNextOccurrence
    /// 折叠/展开(视图级动作,只读文件也可用)
    case fold, unfold, foldAll, unfoldAll
}

/// 编辑器光标状态(行、列均 1 起始;`selectedLength` 为选中的字符数)。
public struct EditorCaret: Equatable, Sendable {
    public var line: Int
    public var column: Int
    public var selectedLength: Int

    /// - Parameters:
    ///   - line: 行号
    ///   - column: 列号
    ///   - selectedLength: 选中字符数
    public init(line: Int, column: Int, selectedLength: Int) {
        self.line = line
        self.column = column
        self.selectedLength = selectedLength
    }
}

/// 行标记(用于 Diff 与 Agent 跟随)。
public enum LineMarker: Sendable {
    case added, removed, modified, agent
}
