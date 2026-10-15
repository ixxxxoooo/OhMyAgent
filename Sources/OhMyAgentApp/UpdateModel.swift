// @author ygw
// 应用更新模型:封装版本信息、手动/自动检查与「有新版本」系统通知。

import AppKit
import ChatKit
import Foundation
import Observation

/// 更新状态(设置页与菜单共享)。
@MainActor
@Observable
final class UpdateModel {
    static let shared = UpdateModel()

    /// 检查状态。
    enum State: Equatable {
        case idle
        case checking
        case result(UpdateResult)
    }

    private(set) var state: State = .idle

    /// 当前短版本号。
    var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0" }
    /// 当前构建号。
    var currentBuild: Int { Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0 }

    /// 立即检查更新(忽略节流)。
    func checkNow() {
        guard state != .checking else { return }
        state = .checking
        let defaults = UserDefaults.standard
        let feed = defaults.string(forKey: ClientPrefs.Key.updateFeedURL) ?? ""
        let channel = defaults.string(forKey: ClientPrefs.Key.updateChannel) ?? "stable"
        let version = currentVersion, build = currentBuild
        Task {
            let result = await UpdateChecker.check(feedURL: feed, channel: channel, currentVersion: version, currentBuild: build)
            defaults.set(Date(), forKey: ClientPrefs.Key.updateLastCheck)
            state = .result(result)
        }
    }

    /// 菜单触发的检查:完成后弹出提示框展示结果,发现新版本时可直接前往下载。
    func checkInteractively() {
        checkNow()
        Task {
            for _ in 0..<150 where state == .checking { try? await Task.sleep(for: .milliseconds(200)) }
            guard case .result(let result) = state else { return }
            let alert = NSAlert()
            switch result {
            case .upToDate:
                alert.messageText = String(localized: "已是最新版本")
                alert.informativeText = "OhMyAgent \(currentVersion) (\(currentBuild))"
            case .available(let info):
                alert.messageText = String(localized: "发现新版本 \(info.version)")
                alert.informativeText = info.notes ?? ""
                alert.addButton(withTitle: String(localized: "前往下载"))
                alert.addButton(withTitle: String(localized: "稍后"))
            case .unsupportedSystem(let info):
                alert.messageText = String(localized: "新版本 \(info.version) 需要 macOS \(info.minimumSystemVersion ?? "")")
            case .failed(let message):
                alert.messageText = String(localized: "检查更新失败")
                alert.informativeText = message
                alert.alertStyle = .warning
            }
            NSApp.activate()
            if alert.runModal() == .alertFirstButtonReturn, case .available(let info) = result { openDownload(info) }
        }
    }

    /// 启动后的自动检查:开启自动更新、已配置发布源且距上次超过 24 小时才执行;发现新版本时发系统通知。
    func autoCheckIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: ClientPrefs.Key.autoUpdate) as? Bool ?? true,
              !(defaults.string(forKey: ClientPrefs.Key.updateFeedURL) ?? "").isEmpty,
              UpdateChecker.shouldAutoCheck(last: defaults.object(forKey: ClientPrefs.Key.updateLastCheck) as? Date) else { return }
        checkNow()
        Task {
            // 等待检查结束后提示
            for _ in 0..<100 where state == .checking { try? await Task.sleep(for: .milliseconds(200)) }
            if case .result(.available(let info)) = state {
                AppNotifier.send(title: String(localized: "OhMyAgent 有新版本"), message: "\(info.version)")
            }
        }
    }

    /// 在浏览器中打开下载地址(仅 http/https)。
    /// - Parameter info: 版本信息
    func openDownload(_ info: UpdateInfo) {
        guard let url = URL(string: info.url), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        NSWorkspace.shared.open(url)
    }
}
