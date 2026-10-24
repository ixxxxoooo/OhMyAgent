// @author ixxxxoooo
// 切换文件不闪屏:新文件的编辑器在后台挂载并完成首帧语法着色之前,继续显示上一个文件;
// 就绪后一次换过去,用户只看到文字内容变化,不会经过「空白 → 无色文字 → 着色」的中间帧。

import EditorKit
import Observation
import SwiftUI
import WorkbenchKit

/// 各文件编辑器的就绪登记(每个 IDE 窗口一份)。
@MainActor
@Observable
final class EditorSwapGate {
    /// 已完成首帧着色且视图仍挂载的文件路径
    private(set) var ready: Set<String> = []

    /// 登记或注销某文件的就绪状态。
    /// - Parameters:
    ///   - path: 文件路径
    ///   - ready: true 为已就绪;false 为视图已卸载
    func mark(_ path: String, ready isReady: Bool) {
        if isReady { ready.insert(path) } else { ready.remove(path) }
    }
}

/// 是否继续保留旧标签的纯判定。
enum EditorSwapPolicy {
    /// 等待新编辑器就绪的最长时间(超时直接换,避免加载失败时界面卡住)
    static let timeout: Duration = .milliseconds(500)

    /// 标签的视图槽位标识:文件标签按路径区分(预览标签原地换文件时新旧视图可共存),其余标签只按 id。
    /// - Parameter tab: 标签
    /// - Returns: 槽位键
    static func slotKey(_ tab: WorkbenchTab) -> String {
        if case .file(let path) = tab.kind { return "\(tab.id.uuidString)|\(path)" }
        return tab.id.uuidString
    }

    /// 目标文件是否由原生编辑器渲染(只有它会上报就绪;图片、PDF、Markdown 就地渲染不等待)。
    /// - Parameter path: 文件路径
    /// - Returns: 是否值得等待
    static func isHoldable(path: String) -> Bool {
        if let kind = FilePreviewKind.of(path: path), kind.isBinary { return false }
        return EditorEngine.usesNative(for: SyntaxLanguage.detect(path: path))
    }

    /// 正在显示的旧标签是否还值得保留:它仍在组里,或它被新激活的预览标签「原位替换」了
    /// (预览替换会新建标签并顶掉旧标签,组内标签数不变;关闭标签则数量减少,不保留)。
    /// - Parameters:
    ///   - shownID: 正在显示的标签 id
    ///   - siblingIDs: 显示该标签时组内的全部标签 id
    ///   - currentIDs: 组内当前的全部标签 id
    ///   - targetID: 新激活标签的 id
    /// - Returns: 是否保留
    static func isShownKeepable(shownID: UUID, siblingIDs: [UUID], currentIDs: [UUID], targetID: UUID) -> Bool {
        if currentIDs.contains(shownID) { return true }
        return currentIDs.count == siblingIDs.count && !siblingIDs.contains(targetID)
    }

    /// 是否应继续显示旧标签。
    /// - Parameters:
    ///   - targetPath: 新激活标签的文件路径(非文件标签为 nil)
    ///   - targetKey: 新激活标签的槽位键
    ///   - shownKey: 当前正在显示的槽位键(首次为 nil)
    ///   - shownAlive: 正在显示的标签是否仍然存在(已被关闭则不保留)
    ///   - ready: 已就绪的文件路径
    /// - Returns: true 表示新编辑器未就绪,继续显示旧标签
    static func shouldHold(targetPath: String?, targetKey: String, shownKey: String?, shownAlive: Bool, ready: Set<String>) -> Bool {
        guard let targetPath, let shownKey, shownAlive, shownKey != targetKey else { return false }
        return isHoldable(path: targetPath) && !ready.contains(targetPath)
    }
}

extension EnvironmentValues {
    /// Agent 窗口标签组的就绪登记(IDE 窗口走 `ideFileHost.markReady`,此值为 nil)。
    @Entry var editorSwapGate: EditorSwapGate?
}
