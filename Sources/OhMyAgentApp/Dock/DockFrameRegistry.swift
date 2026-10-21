// @author ixxxxoooo
import AppKit
import WorkbenchKit

/// 各标签组在窗口内的位置登记表,供 ⌘W 按鼠标所在区域决定关闭哪个标签组的标签。
@MainActor
final class DockFrameRegistry {
    static let shared = DockFrameRegistry()

    private struct Entry { var host: DockHost; var frame: CGRect }
    private var entries: [UUID: Entry] = [:]

    /// 登记或更新标签组的窗口坐标(左上角为原点)。
    /// - Parameters:
    ///   - groupID: 标签组 ID
    ///   - host: 所属停靠区
    ///   - frame: 窗口坐标系下的矩形
    func update(group groupID: UUID, host: DockHost, frame: CGRect) {
        entries[groupID] = Entry(host: host, frame: frame)
    }

    /// 移除已消失的标签组。
    func remove(group groupID: UUID) { entries[groupID] = nil }

    /// 当前鼠标所在的标签组。
    /// - Returns: 停靠区与标签组 ID;鼠标不在任何标签组内时为 nil
    func groupUnderMouse() -> (host: DockHost, groupID: UUID)? {
        guard let window = NSApp.keyWindow, let content = window.contentView else { return nil }
        let raw = window.mouseLocationOutsideOfEventStream
        let point = CGPoint(x: raw.x, y: content.isFlipped ? raw.y : content.bounds.height - raw.y)
        guard let hit = entries.first(where: { $0.value.frame.contains(point) }) else { return nil }
        return (hit.value.host, hit.key)
    }
}
