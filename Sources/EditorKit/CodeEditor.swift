// @author ygw
// SwiftUI 封装:将 AppKit 编辑器嵌入 SwiftUI 视图层级。

import SwiftUI

/// SwiftUI 版代码编辑器。
public struct CodeEditor: NSViewRepresentable {
    public var text: String
    public var language: SyntaxLanguage
    public var isEditable: Bool
    public var revealLine: Int?
    public var markers: [Int: LineMarker]

    /// 创建编辑器。
    /// - Parameters:
    ///   - text: 文本内容
    ///   - language: 语言
    ///   - isEditable: 是否可编辑
    ///   - revealLine: 需要跳转的行(1 起始)
    ///   - markers: 行标记
    public init(text: String, language: SyntaxLanguage, isEditable: Bool = false, revealLine: Int? = nil, markers: [Int: LineMarker] = [:]) {
        self.text = text
        self.language = language
        self.isEditable = isEditable
        self.revealLine = revealLine
        self.markers = markers
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public func makeNSView(context: Context) -> CodeEditorView {
        let view = CodeEditorView(isEditable: isEditable)
        context.coordinator.loadedText = text
        view.setText(text, language: language)
        return view
    }

    public func updateNSView(_ view: CodeEditorView, context: Context) {
        if context.coordinator.loadedText != text || context.coordinator.loadedLanguage != language {
            context.coordinator.loadedText = text
            context.coordinator.loadedLanguage = language
            view.setText(text, language: language)
        }
        view.textView.isEditable = isEditable
        view.lineMarkers = markers
        if let line = revealLine, context.coordinator.revealedLine != line {
            context.coordinator.revealedLine = line
            // 等待索引就绪后再跳转
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(60))
                view.reveal(line: line)
            }
        }
    }

    /// 记录已装载状态,避免重复装载大文本。
    @MainActor
    public final class Coordinator {
        var loadedText: String?
        var loadedLanguage: SyntaxLanguage?
        var revealedLine: Int?
    }
}
