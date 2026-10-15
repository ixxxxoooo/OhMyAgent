// @author ygw
// 终端控制器:每个终端标签对应一个 PTY 子进程(用户登录 shell)+ SwiftTerm 渲染视图。
// 视图与进程由 TerminalStore 持有,标签切换/隐藏不会终止会话;关闭标签才会结束进程。

import AppKit
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
    @ObservationIgnored private var process: LocalProcess?
    @ObservationIgnored private let executable: String
    @ObservationIgnored private let arguments: [String]
    @ObservationIgnored private let extraEnvironment: [String: String]

    /// - Parameters:
    ///   - id: 终端标识(对应标签的 `.terminal(id:)`)
    ///   - directory: 启动目录(不存在时退回主目录)
    ///   - executable: 可执行文件;默认读取 `$SHELL`,缺省 `/bin/zsh`
    ///   - arguments: 参数;默认 `-l`(登录 shell,加载用户的 profile)
    ///   - environment: 额外环境变量(测试用)
    init(id: String, directory: String, executable: String? = nil, arguments: [String]? = nil, environment: [String: String] = [:]) {
        self.id = id
        var isDir: ObjCBool = false
        let valid = FileManager.default.fileExists(atPath: directory, isDirectory: &isDir) && isDir.boolValue
        self.directory = valid ? directory : NSHomeDirectory()
        let shell = executable ?? ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        self.executable = shell
        self.arguments = arguments ?? ["-l"]
        self.extraEnvironment = environment
        let terminalView = TerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 360))
        terminalView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        terminalView.nativeBackgroundColor = .textBackgroundColor
        terminalView.nativeForegroundColor = .labelColor
        terminalView.optionAsMetaKey = true
        view = terminalView
        terminalView.terminalDelegate = self
        start()
    }

    /// 启动(或重新启动)shell 进程。
    func start() {
        guard !isRunning else { return }
        exitCode = nil
        let process = LocalProcess(delegate: self)
        self.process = process
        process.startProcess(executable: executable, args: arguments, environment: Self.environment(extra: extraEnvironment), execName: nil, currentDirectory: directory)
        isRunning = process.running
        Log.ui.info("终端已启动", ["id": id, "shell": (executable as NSString).lastPathComponent, "running": "\(isRunning)"])
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
    nonisolated static func environment(extra: [String: String] = [:]) -> [String] {
        var env = ProcessInfo.processInfo.environment.filter { key, _ in
            !key.hasPrefix("OMA_") && !key.hasPrefix("ANTHROPIC_")
        }
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
        MainActor.assumeIsolated {
            isRunning = false
            self.exitCode = exitCode.flatMap(Self.decodeWaitStatus)
            Log.ui.info("终端进程已退出", ["id": id, "code": self.exitCode.map { String($0) } ?? "signal"])
        }
    }

    nonisolated func dataReceived(slice: ArraySlice<UInt8>) {
        MainActor.assumeIsolated { view.feed(byteArray: slice) }
    }

    nonisolated func getWindowSize() -> winsize {
        MainActor.assumeIsolated { windowSize() }
    }
}

/// 终端仓库:按标签标识持有控制器,标签关闭后回收。
@MainActor
final class TerminalStore {
    static let shared = TerminalStore()
    private(set) var controllers: [String: TerminalController] = [:]
    /// 已登记但尚未创建控制器的启动目录
    private var pendingDirectories: [String: String] = [:]

    private init() {}

    /// 登记终端启动目录(打开标签前调用)。
    func register(id: String, directory: String) {
        pendingDirectories[id] = directory
    }

    /// 获取(必要时创建)终端控制器。
    /// - Parameters:
    ///   - id: 终端标识
    ///   - fallbackDirectory: 未登记目录时使用的目录
    func controller(for id: String, fallbackDirectory: String) -> TerminalController {
        if let existing = controllers[id] { return existing }
        let controller = TerminalController(id: id, directory: pendingDirectories[id] ?? fallbackDirectory)
        controllers[id] = controller
        return controller
    }

    /// 终止并移除不再被任何标签引用的终端。
    /// - Parameter keeping: 仍然存在的终端标识
    func prune(keeping: Set<String>) {
        for (id, controller) in controllers where !keeping.contains(id) && !id.hasPrefix("bottom:") {
            controller.terminate()
            controllers[id] = nil
            pendingDirectories[id] = nil
        }
    }

    /// 终止并移除指定终端。
    func remove(_ id: String) {
        controllers[id]?.terminate()
        controllers[id] = nil
        pendingDirectories[id] = nil
    }
}
