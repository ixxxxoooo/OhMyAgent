// @author ixxxxoooo
// 「在 IDE 中打开」:检测本机已安装的常见编辑器/IDE,把项目目录交给它打开。

import AppKit
import OMLog

/// 一个已安装的 IDE。
struct InstalledIDE: Identifiable, Equatable {
    var id: String { bundleID }
    let name: String
    let bundleID: String
    let appURL: URL
}

/// IDE 启动器。
@MainActor
enum IDELauncher {
    /// 已知的 IDE(显示名 → Bundle ID),按常用程度排序。
    private static let known: [(name: String, bundleID: String)] = [
        ("Cursor", "com.todesktop.230313mzl4w4u92"),
        ("VS Code", "com.microsoft.VSCode"),
        ("Antigravity", "com.google.antigravity"),
        ("Windsurf", "com.exafunction.windsurf"),
        ("Zed", "dev.zed.Zed"),
        ("Xcode", "com.apple.dt.Xcode"),
        ("Android Studio", "com.google.android.studio"),
        ("IntelliJ IDEA", "com.jetbrains.intellij"),
        ("PyCharm", "com.jetbrains.pycharm"),
        ("Sublime Text", "com.sublimetext.4"),
    ]

    /// 本机已安装的 IDE。
    static var installed: [InstalledIDE] {
        known.compactMap { item in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: item.bundleID).map {
                InstalledIDE(name: item.name, bundleID: item.bundleID, appURL: $0)
            }
        }
    }

    /// 用指定 IDE 打开目录。
    /// - Parameters:
    ///   - directory: 项目目录
    ///   - ide: 目标 IDE
    static func open(_ directory: URL, with ide: InstalledIDE) {
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([directory], withApplicationAt: ide.appURL, configuration: configuration) { _, error in
            if let error { Log.ui.error("在 IDE 中打开失败", ["ide": ide.name, "error": "\(error)"]) }
        }
    }
}
