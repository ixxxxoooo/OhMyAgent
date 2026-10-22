// @author ixxxxoooo
// 应用更新模型:封装版本信息、手动/自动检查与「有新版本」系统通知。

import AppKit
import ChatKit
import Foundation
import Network
import OMLog
import Observation
import os

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

    /// 下载与安装阶段(侧栏按钮与设置页共享)。
    enum Phase: Equatable {
        case none
        case downloading(Double)
        case ready(StagedUpdate)
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var phase: Phase = .none
    /// 最近一次检查发现的可用版本。
    private(set) var availableInfo: UpdateInfo?
    @ObservationIgnored private var downloadTask: Task<Void, Never>?
    @ObservationIgnored private var restartRequested = false
    @ObservationIgnored private var idleTask: Task<Void, Never>?

    /// 当前更新方式。
    var mode: UpdateMode { UpdateMode(rawValue: UserDefaults.standard.string(forKey: ClientPrefs.Key.updateMode) ?? "") ?? .download }
    /// 开发版与演示模式只下载、不做自替换(避免用正式包覆盖开发版)。
    var canSelfInstall: Bool { !AppEnv.isDev() && !DemoLaunch.isActive }

    /// 启动时恢复上次已下载好的更新,并按需启动空闲自动安装。
    func restoreStaged() {
        if let failure = UpdateInstaller.takeInstallFailure() {
            Log.update.error("上次更新安装失败,已清理暂存", ["detail": failure])
            let message = String(localized: "无法替换应用(可能没有写入权限),请从发布页手动下载安装。")
            phase = .failed(message)
            AppNotifier.send(title: String(localized: "更新安装失败"), message: message)
        }
        if let staged = UpdateInstaller.loadStaged(currentVersion: currentVersion, currentBuild: currentBuild) { phase = .ready(staged) }
        startIdleWatcher()
    }

    /// 当前短版本号。
    var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0" }
    /// 当前构建号。
    var currentBuild: Int { Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0 }

    /// 立即检查更新(忽略节流)。
    func checkNow() {
        guard state != .checking else { return }
        state = .checking
        let defaults = UserDefaults.standard
        let feed = UpdateChecker.resolvedFeedURL(defaults.string(forKey: ClientPrefs.Key.updateFeedURL))
        let channel = defaults.string(forKey: ClientPrefs.Key.updateChannel) ?? "stable"
        let version = currentVersion, build = currentBuild
        Task {
            let result = await UpdateChecker.check(feedURL: feed, channel: channel, currentVersion: version, currentBuild: build)
            defaults.set(Date(), forKey: ClientPrefs.Key.updateLastCheck)
            Log.update.info("更新检查完成", ["feed": feed.isEmpty ? "-" : feed, "channel": channel, "result": "\(result)"])
            state = .result(result)
            if case .available(let info) = result { availableInfo = info; autoDownloadIfAllowed(info) } else { availableInfo = nil }
        }
    }

    /// 开始下载并暂存更新(已在下载或已就绪时忽略)。
    /// - Parameter info: 要下载的版本
    func startDownload(_ info: UpdateInfo) {
        if case .downloading = phase { return }
        if case .ready(let staged) = phase, staged.version == info.version { return }
        phase = .downloading(0)
        downloadTask = Task {
            do {
                let staged = try await UpdateInstaller.download(info) { value in
                    Task { @MainActor in if case .downloading = UpdateModel.shared.phase { UpdateModel.shared.phase = .downloading(value) } }
                }
                phase = .ready(staged)
                if mode != .auto { AppNotifier.send(title: String(localized: "新版本已下载"), message: String(localized: "点击侧栏「更新」即可完成更新 \(info.version)")) }
            } catch {
                Log.update.error("下载更新失败", ["error": error.localizedDescription])
                phase = .failed(error.localizedDescription)
            }
        }
    }

    /// 自动下载:更新方式不是「仅提醒」且网络不计费、未开启低数据模式时才下载。
    private func autoDownloadIfAllowed(_ info: UpdateInfo) {
        guard mode != .remind else { return }
        Task {
            let path = await Self.currentPath()
            guard UpdateTiming.canDownloadNow(isExpensive: path.isExpensive, isConstrained: path.isConstrained) else {
                Log.update.info("网络计费或受限,推迟下载更新"); return
            }
            startDownload(info)
        }
    }

    /// 取一次当前网络路径。
    private static func currentPath() async -> NWPath {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            let resumed = OSAllocatedUnfairLock(initialState: false)
            monitor.pathUpdateHandler = { path in
                let first = resumed.withLock { done -> Bool in defer { done = true }; return !done }
                guard first else { return }
                monitor.cancel(); continuation.resume(returning: path)
            }
            monitor.start(queue: DispatchQueue(label: "oma.update.path"))
        }
    }

    /// 侧栏按钮点击:已就绪则重启更新;否则开始下载(下载完成后再点重启)。
    func performPrimaryAction() {
        switch phase {
        case .ready: installAndRestart()
        case .downloading: break
        case .none, .failed:
            guard let info = availableInfo else { return }
            startDownload(info)
        }
    }

    /// 重启并安装已下载的更新。
    func installAndRestart() {
        guard case .ready = phase else { return }
        guard canSelfInstall else {
            // 不能在按钮点击的同一次事件里 runModal(事件循环嵌套会让弹窗收不到点击),推迟到下一轮主线程
            Task { @MainActor in
                OMDialog.alert(title: String(localized: "开发版不支持自动更新"), message: String(localized: "请用 Scripts/promote.sh 更新稳定版。"))
            }
            return
        }
        restartRequested = true
        NSApp.terminate(nil)
    }

    /// 退出被取消(未保存文件对话框里点了取消,或保存失败):撤销「重启更新」请求。
    /// 不能按固定时长复位——用户可能在对话框上停留很久,复位早了会导致更新没装或装了不重启。
    func terminationCancelled() {
        guard restartRequested else { return }
        restartRequested = false
        Log.update.info("退出已取消,撤销重启更新")
    }

    /// 应用退出时调用:用户点了重启更新,或「自动」模式下有已下载的更新,则交给替换脚本完成安装。
    func applyOnQuitIfNeeded() {
        guard case .ready(let staged) = phase, canSelfInstall, restartRequested || mode == .auto else { return }
        WhatsNew.remember(version: staged.version, notes: staged.notes)
        do {
            try UpdateInstaller.launchReplacer(staged: staged, targetApp: Bundle.main.bundlePath, relaunch: restartRequested)
            Log.update.info("已交给替换脚本安装更新", ["version": staged.version, "relaunch": "\(restartRequested)"])
        } catch {
            Log.update.error("启动更新替换脚本失败", ["error": error.localizedDescription])
        }
    }

    /// 「自动」模式的最佳时间:电脑空闲 15 分钟以上且没有会话在运行/等待输入时,自动重启更新。
    private func startIdleWatcher() {
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            var ticks = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                ticks += 1
                // 长时间不退出的用户:每小时重新检查一次
                if ticks % 60 == 0, let self, UserDefaults.standard.object(forKey: ClientPrefs.Key.autoUpdate) as? Bool ?? true { self.checkNow() }
                guard let self, self.mode == .auto, self.canSelfInstall, case .ready = self.phase else { continue }
                guard let anyInput = CGEventType(rawValue: ~0) else { continue }
                let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
                let center = AttentionCenter.shared
                let busy = center.count(of: .running) + center.count(of: .needsInput)
                if UpdateTiming.canInstallNow(idleSeconds: idle, busySessions: busy) {
                    Log.update.info("空闲且无运行会话,自动重启安装更新", ["idle": "\(Int(idle))"])
                    // 退出被取消时继续监视,下次满足条件再试
                    self.installAndRestart()
                }
            }
        }
    }

    /// 菜单触发的检查:完成后弹出提示框展示结果,发现新版本时可直接前往下载。
    func checkInteractively() {
        checkNow()
        Task {
            for _ in 0..<150 where state == .checking { try? await Task.sleep(for: .milliseconds(200)) }
            guard case .result(let result) = state else { return }
            NSApp.activate()
            switch result {
            case .upToDate:
                OMDialog.alert(title: String(localized: "已是最新版本"), message: "OhMyAgent \(currentVersion) (\(currentBuild))")
            case .available(let info):
                let choice = OMDialog.show(title: String(localized: "发现新版本 \(info.version)"), message: WhatsNew.bulletList(info.notes, limit: 50),
                                           buttons: [.cancel(String(localized: "稍后")), .primary(String(localized: "前往下载"))]).index
                if choice == 1 { openDownload(info) }
            case .unsupportedSystem(let info):
                OMDialog.alert(title: String(localized: "新版本 \(info.version) 需要 macOS \(info.minimumSystemVersion ?? "")"))
            case .failed(let message):
                OMDialog.alert(title: String(localized: "检查更新失败"), message: message, isError: true)
            }
        }
    }

    /// 更新完成后首次启动:弹窗展示新版本说明(只展示一次)。
    private func showWhatsNewIfNeeded() {
        guard let news = WhatsNew.takePending(currentVersion: currentVersion) else { return }
        let body = WhatsNew.bulletList(news.notes)
        NSApp.activate()
        OMDialog.alert(title: String(localized: "已更新到 \(news.version)"), message: body.isEmpty ? String(localized: "感谢使用 OhMyAgent。") : body)
    }

    /// 一分钟内刚检查过(避免启动与定时检查重叠)。
    private var checkedRecently: Bool {
        (UserDefaults.standard.object(forKey: ClientPrefs.Key.updateLastCheck) as? Date).map { Date().timeIntervalSince($0) < 60 } ?? false
    }

    /// 只恢复一次暂存状态。
    private func restoreStagedOnce() { if idleTask == nil { restoreStaged() } }

    /// 启动后的自动检查:开启自动更新才执行(请求很小,每次启动都查,发现的新版本才能在侧栏出现按钮);发现新版本时发系统通知。
    func autoCheckIfNeeded() {
        showWhatsNewIfNeeded()
        let defaults = UserDefaults.standard
        restoreStagedOnce()
        guard defaults.object(forKey: ClientPrefs.Key.autoUpdate) as? Bool ?? true,
              !checkedRecently else { return }
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
