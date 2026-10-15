// @author ygw
// 工具链解析器:后台解析登录 shell 环境并定位 node / claude / 适配器,结果在进程内缓存。
// 登录 shell 环境解析约需 1 秒,绝不放在启动关键路径上同步等待。

import AgentHost
import Foundation

/// 工具链解析器(进程内单例)。
public actor Toolchain {
    public static let shared = Toolchain()

    private var cached: LocatedTools?
    private var inflight: Task<LocatedTools, Never>?
    /// 用户在高级设置中指定的路径(键:node / claude / adapter)。
    public var overrides: [String: String] = [:]

    private init() {}

    /// 设置路径覆盖并使缓存失效。
    /// - Parameter value: 覆盖项
    public func setOverrides(_ value: [String: String]) {
        overrides = value
        cached = nil
    }

    /// 获取工具链(首次会触发后台解析)。
    /// - Returns: 定位结果
    public func resolve() async -> LocatedTools {
        if let cached { return cached }
        if let inflight { return await inflight.value }
        let overrides = overrides
        let task = Task.detached(priority: .userInitiated) { () -> LocatedTools in
            let environment = await ShellEnvironment.resolve()
            return ExecutableLocator.locate(overrides: overrides, projectRoot: Toolchain.projectRoot(), environment: environment)
        }
        inflight = task
        let result = await task.value
        cached = result
        inflight = nil
        return result
    }

    /// 查找工程根目录(开发期用于定位 `Vendor/acp`):环境变量 > 自可执行文件向上查找。
    /// - Returns: 工程根目录;找不到时为 nil
    public nonisolated static func projectRoot() -> String? {
        if let value = ProcessInfo.processInfo.environment["OMA_PROJECT_ROOT"], !value.isEmpty { return value }
        var url = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0]).deletingLastPathComponent()
        for _ in 0..<8 {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Vendor/acp").path) { return url.path }
            url.deleteLastPathComponent()
        }
        return nil
    }

    /// 选择默认 Agent 描述符:`OMA_AGENT=fake` 时使用与可执行文件同目录的 FakeAgent(用于 UI 开发与测试)。
    /// - Returns: 描述符
    public nonisolated static func defaultDescriptor() -> AgentDescriptor {
        if ProcessInfo.processInfo.environment["OMA_AGENT"] == "fake" {
            let dir = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0]).deletingLastPathComponent()
            let path = dir.appendingPathComponent("FakeAgent").path
            return AgentDescriptor(id: "fake", name: "Fake Agent", kind: .genericACP, command: path, summary: "脚本化测试 Agent")
        }
        // 调试:OMA_AGENT=direct 强制使用直连兜底通道
        if ProcessInfo.processInfo.environment["OMA_AGENT"] == "direct" { return .claudeDirect }
        return AgentRegistryStore().load().resolvedDefault
    }
}
