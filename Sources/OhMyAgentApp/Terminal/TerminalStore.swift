// @author ixxxxoooo
// 终端仓库:按标签标识持有 TerminalController,标签关闭后回收。

import Foundation

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
