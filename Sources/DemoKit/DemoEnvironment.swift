// @author ixxxxoooo
// 演示模式隔离层:解析启动参数、准备沙盒、把进程主目录重定向到沙盒,确保不污染真实用户数据。

import Foundation
import OMLog

/// 演示模式环境(`OMA_DEMO=1` 启用)。
///
/// 隔离策略:
/// - 工作台状态:`workbenchStoreURL` 指向沙盒,不触碰 `~/Library/Application Support/OhMyAgent/workbench.json`;
/// - 主目录:`redirectHome()` 设置 `CFFIXED_USER_HOME`/`HOME`,使 `NSHomeDirectory()`、`homeDirectoryForCurrentUser`、
///   Application Support(提供商与密钥)、`~/.claude` 全部落到沙盒 `home/`;
/// - 最近项目/会话:使用独立的 UserDefaults suite(`defaultsSuiteName`);
/// - 副作用:关闭自动更新检查与系统通知(由应用层依据 `isEnabled` 判断);
/// - 注意:外观、快捷键等纯界面偏好仍沿用 `UserDefaults.standard`(有意共享,演示时外观与日常一致)。
public struct DemoEnvironment: Sendable {
    /// 演示用 UserDefaults suite 名称
    public static let defaultsSuiteName = "com.ixxxxoooo.OhMyAgent.demo"

    /// 沙盒路径
    public let paths: DemoPaths
    /// 启动时是否要求重建沙盒(`OMA_DEMO_RESET=1`)
    public let reset: Bool
    /// 启动后自动运行的场景名(`OMA_DEMO_SCENARIO`)
    public let scenario: String?

    /// - Parameters:
    ///   - paths: 沙盒路径
    ///   - reset: 是否重建
    ///   - scenario: 自动运行的场景名
    public init(paths: DemoPaths, reset: Bool = false, scenario: String? = nil) {
        self.paths = paths
        self.reset = reset
        self.scenario = scenario
    }

    /// 是否启用演示模式。
    /// - Parameter environment: 环境变量(测试可注入)
    public static func isEnabled(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment["OMA_DEMO"] == "1"
    }

    /// 从环境变量解析演示环境;未启用时返回 nil。
    /// - Important: 必须在 `redirectHome()` 之前调用,否则默认沙盒根目录会落进已重定向的主目录。
    /// - Parameter environment: 环境变量(测试可注入)
    public static func current(environment: [String: String] = ProcessInfo.processInfo.environment) -> DemoEnvironment? {
        guard isEnabled(environment: environment) else { return nil }
        let scenario = environment["OMA_DEMO_SCENARIO"].flatMap { $0.isEmpty ? nil : $0 }
        return DemoEnvironment(paths: .resolve(environment: environment), reset: environment["OMA_DEMO_RESET"] == "1", scenario: scenario)
    }

    // MARK: 隔离后的位置

    /// 演示版工作台状态文件
    public var workbenchStoreURL: URL { paths.workbenchFile }
    /// 演示用主目录(内含 `.claude`)
    public var homeDirectory: URL { paths.home }
    /// 演示用提供商/密钥目录(主目录重定向后与 `ProviderStorage.defaultDirectory` 一致)
    public var providerDirectory: URL { paths.home.appendingPathComponent("Library/Application Support/OhMyAgent", isDirectory: true) }

    /// 演示用 UserDefaults(独立 suite,不与真实偏好混用)。
    public var defaults: UserDefaults {
        UserDefaults(suiteName: Self.defaultsSuiteName) ?? .standard
    }

    // MARK: 准备

    /// 准备沙盒:生成(或复用)演示项目;`reset` 时同时清空演示 suite。
    /// - Returns: 演示项目列表
    public func prepare() async throws -> [DemoProjectInfo] {
        if reset { UserDefaults(suiteName: Self.defaultsSuiteName)?.removePersistentDomain(forName: Self.defaultsSuiteName) }
        let infos = try await DemoWorkspace.materialize(paths: paths, reset: reset)
        try FileManager.default.createDirectory(at: providerDirectory, withIntermediateDirectories: true)
        try DemoSeed.seed(paths: paths, infos: infos)
        return infos
    }

    /// 同步准备沙盒(仅用于应用启动早期:此时 UI 尚未构建,无法 await)。
    ///
    /// 首次生成约数秒;之后沙盒版本一致即直接复用,几乎无耗时。
    /// - Returns: 演示项目列表;失败时返回空并记录日志
    public func prepareBlocking() -> [DemoProjectInfo] {
        final class Box: @unchecked Sendable { var value: [DemoProjectInfo] = [] }
        let box = Box()
        let semaphore = DispatchSemaphore(value: 0)
        let environment = self
        Task.detached {
            do { box.value = try await environment.prepare() }
            catch { Log.app.error("演示沙盒准备失败", ["error": "\(error)", "root": environment.paths.root.path]) }
            semaphore.signal()
        }
        semaphore.wait()
        return box.value
    }

    /// 把进程主目录重定向到沙盒(进程内一次性生效,必须在任何读取主目录的代码之前调用)。
    ///
    /// `CFFIXED_USER_HOME` 同时影响 `NSHomeDirectory()`、`homeDirectoryForCurrentUser` 与 Application Support;
    /// `HOME` 让子进程(终端 shell、git、Agent)也使用沙盒主目录。
    public func redirectHome() {
        setenv("CFFIXED_USER_HOME", paths.home.path, 1)
        setenv("HOME", paths.home.path, 1)
    }
}
