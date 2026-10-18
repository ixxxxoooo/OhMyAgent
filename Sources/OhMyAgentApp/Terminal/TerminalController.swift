// @author ixxxxoooo
// 终端控制器:每个终端标签对应一个 PTY 子进程(用户登录 shell)+ SwiftTerm 渲染视图。
// 视图与进程由 TerminalStore 持有,标签切换/隐藏不会终止会话;关闭标签才会结束进程。

import AppKit
import DesignSystem
import Foundation
import Observation
import OMLog
import SwiftTerm

/// 单个终端会话。
@MainActor
@Observable
final class TerminalController: Identifiable {
    nonisolated let id: String
    /// 启动目录
    let directory: String
    /// 终端(程序通过 OSC 设置的)标题;空表示未设置
    private(set) var title = ""
    /// 进程是否仍在运行
    private(set) var isRunning = false
    /// 退出码(信号终止时为 nil)
    private(set) var exitCode: Int32?
    /// 渲染视图(AppKit)
    @ObservationIgnored let view: TerminalView
    /// 当前持有渲染视图的宿主(见 `TerminalHostView.Coordinator`)
    @ObservationIgnored weak var hostToken: AnyObject?
    @ObservationIgnored private var process: LocalProcess?
    /// 已登记到资源采样的 shell pid(退出时注销)。
    @ObservationIgnored private var registeredPID: Int32?
    /// 自己的子进程退出监听。SwiftTerm 1.11.x 在读到 EOF 时会取消它内部的退出监听,
    /// 导致 `processTerminated` 回调丢失(被 SIGHUP 的 shell 会一直显示为运行中),所以这里独立兜底并收尸。
    @ObservationIgnored private var exitMonitor: DispatchSourceProcess?
    @ObservationIgnored private let executable: String
    @ObservationIgnored private let arguments: [String]
    @ObservationIgnored private let extraEnvironment: [String: String]
    /// 已应用到视图的偏好(用于热更新时判断是否有变化)
    @ObservationIgnored private var appliedPrefs: TerminalPrefs

    /// - Parameters:
    ///   - id: 终端标识(对应标签的 `.terminal(id:)`)
    ///   - directory: 启动目录(不存在时退回主目录)
    ///   - executable: 可执行文件;默认读取 `$SHELL`,缺省 `/bin/zsh`
    ///   - arguments: 参数;默认 `-l`(登录 shell,加载用户的 profile)
    ///   - environment: 额外环境变量(测试用)
    ///   - prefs: 终端偏好(字体/光标/回滚/Shell);默认读取用户设置
    init(id: String, directory: String, executable: String? = nil, arguments: [String]? = nil, environment: [String: String] = [:], prefs: TerminalPrefs = .load()) {
        self.id = id
        var isDir: ObjCBool = false
        let valid = FileManager.default.fileExists(atPath: directory, isDirectory: &isDir) && isDir.boolValue
        self.directory = valid ? directory : NSHomeDirectory()
        self.executable = executable ?? prefs.resolvedShell()
        self.arguments = arguments ?? prefs.shellArguments
        self.extraEnvironment = environment
        self.appliedPrefs = prefs
        let terminalView = TerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 360))
        view = terminalView
        terminalView.terminalDelegate = self
        // 回滚行数只能在创建时设定(视图尚为空,重置缓冲不丢内容)
        terminalView.getTerminal().options.scrollback = prefs.scrollback
        terminalView.getTerminal().resetToInitialState()
        TerminalOSC.install(on: terminalView)
        applyPrefs(prefs, initial: true)
        applyTheme()
        // 设置页修改偏好:字体/光标/Option 键热更新(Shell 与回滚仅对新终端生效)
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadPrefs() }
        }
        // 主题切换/系统明暗变化:热更新终端配色(弱引用,控制器释放后回调为空操作)
        NotificationCenter.default.addObserver(forName: ThemeRuntime.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyTheme() }
        }
        start()
    }

    /// 读取最新偏好并在有变化时应用。
    func reloadPrefs() {
        let latest = TerminalPrefs.load()
        guard latest != appliedPrefs else { return }
        applyPrefs(latest, initial: false)
    }

    /// 把偏好应用到渲染视图(字体、光标样式、Option 键)。
    /// - Parameters:
    ///   - prefs: 偏好快照
    ///   - initial: 是否创建时的首次应用(首次必定全量应用)
    func applyPrefs(_ prefs: TerminalPrefs, initial: Bool) {
        if initial || prefs.fontFamily != appliedPrefs.fontFamily || prefs.fontSize != appliedPrefs.fontSize { view.font = prefs.font }
        if initial || prefs.cursorShape != appliedPrefs.cursorShape || prefs.cursorBlink != appliedPrefs.cursorBlink {
            view.getTerminal().setCursorStyle(prefs.cursorStyle)
        }
        view.optionAsMetaKey = prefs.optionAsMeta
        appliedPrefs = prefs
    }

    /// 把当前主题的终端配色(ANSI 16 色、前景、背景、光标、选区)应用到渲染视图。
    func applyTheme() {
        let colors = OMTerminalPalette.ansi(dark: OMTerminalPalette.currentIsDark).map { color -> SwiftTerm.Color in
            let rgb = color.usingColorSpace(.sRGB) ?? color
            func channel(_ value: CGFloat) -> UInt16 { UInt16((min(max(value, 0), 1) * 65535).rounded()) }
            return SwiftTerm.Color(red: channel(rgb.redComponent), green: channel(rgb.greenComponent), blue: channel(rgb.blueComponent)) // ui-lint:allow SwiftTerm 通道换算,颜色来自 OMTerminalPalette
        }
        view.installColors(colors)
        view.nativeBackgroundColor = OMTerminalPalette.background
        view.nativeForegroundColor = OMTerminalPalette.foreground
        view.caretColor = OMTerminalPalette.cursor
        view.selectedTextBackgroundColor = OMTerminalPalette.selection
    }

    /// 启动(或重新启动)shell 进程。
    func start() {
        guard !isRunning else { return }
        exitCode = nil
        let process = LocalProcess(delegate: self)
        self.process = process
        process.startProcess(executable: executable, args: arguments, environment: Self.environment(extra: extraEnvironment, darkBackground: OMTerminalPalette.currentIsDark), execName: nil, currentDirectory: directory)
        isRunning = process.running
        if isRunning {
            registeredPID = process.shellPid
            ProcessRegistry.shared.register(pid: process.shellPid, role: .terminal, label: (executable as NSString).lastPathComponent)
            watchExit(of: process)
        }
        Log.ui.info("终端已启动", ["id": id, "shell": (executable as NSString).lastPathComponent, "running": "\(isRunning)"])
    }

    /// 监听子进程退出:退出事件触发时尝试收尸并结束状态;若 SwiftTerm 已先处理则为空操作。
    /// - Parameter process: 刚启动的进程
    private func watchExit(of process: LocalProcess) {
        let pid = process.shellPid
        guard pid > 0 else { return }
        exitMonitor?.cancel()
        let monitor = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        monitor.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.process === process, self.isRunning else { return }
                var status: Int32 = 0
                let reaped = waitpid(pid, &status, WNOHANG)
                self.finishProcess(status: reaped == pid ? status : nil)
            }
        }
        monitor.activate()
        exitMonitor = monitor
    }

    /// 进程结束的统一收尾(只生效一次):更新状态、注销资源采样、停止监听、记录日志。
    /// - Parameter status: `waitpid` 状态;信号终止或未取到时为 nil
    private func finishProcess(status: Int32?) {
        guard isRunning else { return }
        isRunning = false
        exitMonitor?.cancel()
        exitMonitor = nil
        if let pid = registeredPID { ProcessRegistry.shared.unregister(pid: pid) }
        registeredPID = nil
        exitCode = status.flatMap(Self.decodeWaitStatus)
        Log.ui.info("终端进程已退出", ["id": id, "code": exitCode.map { String($0) } ?? "signal"])
    }

    /// 终止进程(关闭标签时调用)。交互式 shell 会忽略 SIGTERM,所以先发 SIGHUP(与关闭终端窗口一致),
    /// 1 秒后仍未退出再发 SIGKILL。
    func terminate() {
        guard isRunning, let process else { return }
        let pid = process.shellPid
        guard pid > 0 else { return }
        kill(pid, SIGHUP)
        Log.ui.info("终端已请求终止", ["id": id, "pid": "\(pid)"])
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            if let self, self.isRunning, self.process === process { kill(pid, SIGKILL) }
        }
    }

    /// 解码 `waitpid` 状态:正常退出返回退出码,被信号终止返回 nil。
    nonisolated static func decodeWaitStatus(_ status: Int32) -> Int32? {
        status & 0x7f == 0 ? (status >> 8) & 0xff : nil
    }

    /// 向终端输入文本(例如“在终端运行”)。
    /// - Parameter text: 文本;不会自动追加回车
    func send(_ text: String) {
        guard isRunning, !text.isEmpty else { return }
        process?.send(data: ArraySlice(Array(text.utf8)))
    }

    /// 当前屏幕与滚动缓冲中的全部文本(测试与“复制全部”使用)。
    var screenText: String {
        let data = view.getTerminal().getBufferAsData()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// 构造子进程环境:继承当前环境,去掉本应用的调试/凭据变量,设置终端能力。
    /// - Parameters:
    ///   - extra: 额外环境变量(覆盖同名项)
    ///   - darkBackground: 终端背景是否深色;写入 `COLORFGBG`(`前景;背景` 的 ANSI 序号),
    ///     供不发 OSC 11 查询的程序(旧版 vim、部分 TUI)判断深浅。nil 表示不设置
    nonisolated static func environment(extra: [String: String] = [:], darkBackground: Bool? = nil) -> [String] {
        var env = ProcessInfo.processInfo.environment.filter { key, _ in
            !key.hasPrefix("OMA_") && !key.hasPrefix("ANTHROPIC_") && key != "COLORFGBG"
        }
        if let darkBackground { env["COLORFGBG"] = darkBackground ? "15;0" : "0;15" }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "OhMyAgent"
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        for (key, value) in extra { env[key] = value }
        return env.map { "\($0.key)=\($0.value)" }.sorted()
    }
}

// MARK: - SwiftTerm 回调(均在主线程触发,用 assumeIsolated 回到 MainActor)

extension TerminalController: TerminalViewDelegate {
    nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        MainActor.assumeIsolated {
            guard let process, process.running else { return }
            var size = windowSize()
            _ = PseudoTerminalHelpers.setWinSize(masterPtyDescriptor: process.childfd, windowSize: &size)
        }
    }

    nonisolated func setTerminalTitle(source: TerminalView, title: String) {
        MainActor.assumeIsolated { self.title = title }
    }

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {
        MainActor.assumeIsolated { process?.send(data: data) }
    }

    nonisolated func scrolled(source: TerminalView, position: Double) {}

    nonisolated func clipboardCopy(source: TerminalView, content: Data) {
        guard let text = String(data: content, encoding: .utf8) else { return }
        MainActor.assumeIsolated {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    @MainActor
    fileprivate func windowSize() -> winsize {
        let terminal = view.getTerminal()
        let frame = view.frame
        return winsize(ws_row: UInt16(clamping: terminal.rows), ws_col: UInt16(clamping: terminal.cols),
                       ws_xpixel: UInt16(clamping: Int(frame.width)), ws_ypixel: UInt16(clamping: Int(frame.height)))
    }
}

extension TerminalController: LocalProcessDelegate {
    nonisolated func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        let sourceID = ObjectIdentifier(source)
        MainActor.assumeIsolated {
            guard let process, ObjectIdentifier(process) == sourceID else { return }
            finishProcess(status: exitCode)
        }
    }

    nonisolated func dataReceived(slice: ArraySlice<UInt8>) {
        MainActor.assumeIsolated { view.feed(byteArray: slice) }
    }

    nonisolated func getWindowSize() -> winsize {
        MainActor.assumeIsolated { windowSize() }
    }
}
