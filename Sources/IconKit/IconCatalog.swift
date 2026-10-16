// @author ixxxxoooo
// 图标目录:把应用里沿用的语义名(原 SF Symbol 命名)映射到 Lucide 图标名。
// 视图层只通过 `Image.om(_:)` / `OMLabel` 引用图标,全部由 Lucide 原生路径绘制。

import Foundation

/// 图标目录。
public enum IconCatalog {
    /// 语义名 → Lucide 名。
    public static let symbolToLucide: [String: String] = [
        "arrow.clockwise": "rotate-cw",
        "arrow.right.doc.on.clipboard": "clipboard-paste",
        "arrow.triangle.merge": "git-merge",
        "arrow.triangle.swap": "arrow-left-right",
        "arrow.up": "arrow-up",
        "arrow.up.forward.square": "external-link",
        "arrow.up.right.square": "external-link",
        "arrow.uturn.backward": "undo-2",
        "bolt.horizontal": "zap",
        "brain": "brain",
        "archivebox": "archive",
        "bubble.left": "message-square",
        "bubble.left.fill": "message-square",
        "chart.bar": "chart-column",
        "checklist": "list-checks",
        "checkmark": "check",
        "checkmark.circle": "circle-check",
        "checkmark.circle.fill": "circle-check",
        "checkmark.square.fill": "square-check",
        "chevron.left.forwardslash.chevron.right": "code",
        "chevron.right": "chevron-right",
        "circle": "circle",
        "circle.dotted": "circle-dashed",
        "circle.inset.filled": "circle-dot",
        "command": "command",
        "cpu": "cpu",
        "doc.badge.plus": "file-plus",
        "doc.on.doc": "copy",
        "doc.text": "file-text",
        "exclamationmark.circle": "circle-alert",
        "exclamationmark.circle.fill": "circle-alert",
        "exclamationmark.triangle": "triangle-alert",
        "exclamationmark.triangle.fill": "triangle-alert",
        "folder": "folder",
        "folder.badge.plus": "folder-plus",
        "xmark.circle.fill": "circle-x",
        "folder.fill": "folder-open",
        "gauge.with.needle": "gauge",
        "gearshape": "settings",
        "hand.raised": "hand",
        "info": "info",
        "info.circle": "info",
        "key": "key-round",
        "keyboard": "keyboard",
        "list": "list",
        "list.bullet.clipboard": "clipboard-list",
        "lock": "lock",
        "lock.shield": "shield-check",
        "magnifyingglass": "search",
        "minus.circle": "circle-minus",
        "network": "network",
        "paintbrush": "paintbrush",
        "pencil": "pencil",
        "person.2": "users",
        "person.crop.rectangle.stack": "contact",
        "pin.fill": "pin",
        "plus": "plus",
        "puzzlepiece.extension": "puzzle",
        "questionmark.bubble": "message-circle-question-mark",
        "rectangle.bottomthird.inset.filled": "panel-bottom",
        "server.rack": "server",
        "sidebar.right": "panel-right",
        "slash.circle": "ban",
        "slider.horizontal.3": "sliders-horizontal",
        "sparkles": "sparkles",
        "square": "square",
        "square.and.pencil": "square-pen",
        "square.inset.filled": "square-check",
        "square.stack.3d.up": "layers",
        "stethoscope": "stethoscope",
        "stop.fill": "square",
        "terminal": "terminal",
        "text.magnifyingglass": "text-search",
        "trash": "trash",
        "waveform.path.ecg": "activity",
        "wrench.and.screwdriver": "wrench",
        "xmark": "x",
        "xmark.octagon.fill": "octagon-x",
    ]

    /// 需要实心绘制的语义名(仅「停止」方块)。
    public static let filledSymbols: Set<String> = ["stop.fill"]

    /// 解析语义名对应的 Lucide 名;已经是 Lucide 名(含连字符且存在于数据)时原样返回。
    /// - Parameter symbol: 语义名或 Lucide 名
    /// - Returns: Lucide 名;未知返回 nil
    public static func lucideName(for symbol: String) -> String? {
        if let name = symbolToLucide[symbol] { return name }
        return LucideData.icons[symbol] != nil ? symbol : nil
    }

    /// 全部已打包的 Lucide 图标名。
    public static var bundledNames: Set<String> { Set(LucideData.icons.keys) }

    /// Lucide 版本号。
    public static var lucideVersion: String { LucideData.version }
}
