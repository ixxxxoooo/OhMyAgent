// @author ixxxxoooo
// 工具链解析器:后台解析登录 shell 环境并定位 node / claude / 适配器,结果在进程内缓存。
// 登录 shell 环境解析约需 1 秒,绝不放在启动关键路径上同步等待。

import AgentHost
import Foundation
import OMLog

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
        Log.agent.info("工具链定位", ["node": result.nodePath ?? "未找到", "claude": result.claudePath ?? "未找到", "adapter": result.adapterEntry ?? "未找到"])
        cached = result
        inflight = nil
        return result
    }

    /// 确保适配器可用:定位不到时自动用 npm 安装到 Application Support,并更新缓存(无需重新解析登录 shell 环境)。
    /// - Parameter tools: 当前定位结果
    /// - Returns: 补全适配器后的定位结果;无需安装或缺少 node 时原样返回
    /// - Throws: 安装失败(缺 npm、网络错误等)
    public func ensureAdapter(_ tools: LocatedTools) async throws -> LocatedTools {
        guard tools.adapterEntry == nil, let node = tools.nodePath else { return tools }
        let entry = try await AdapterInstaller.shared.install(nodePath: node, environment: tools.environment)
        var updated = tools
        updated.adapterEntry = entry
        cached = updated
        Log.agent.info("适配器已自动安装并生效", ["adapter": entry])
        return updated
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

    /// 是否处于演示模式(`OMA_DEMO=1`):强制使用脚本化 Agent,避免误连真实 Claude。
    public nonisolated static var isDemoMode: Bool { ProcessInfo.processInfo.environment["OMA_DEMO"] == "1" }

    /// 选择默认 Agent 描述符:演示模式或 `OMA_AGENT=fake` 时使用与可执行文件同目录的 FakeAgent(用于 UI 开发与测试)。
    /// - Returns: 描述符
    public nonisolated static func defaultDescriptor() -> AgentDescriptor {
        if isDemoMode || ProcessInfo.processInfo.environment["OMA_AGENT"] == "fake" {
            let dir = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0]).deletingLastPathComponent()
            let path = dir.appendingPathComponent("FakeAgent").path
            // 演示模式下对外呈现为 Claude Code,界面不出现「Fake」字样
            return AgentDescriptor(id: "fake", name: isDemoMode ? "Claude Code" : "Fake Agent", kind: .genericACP, command: path, summary: String(localized: "脚本化测试 Agent"))
        }
        return AgentRegistryStore().load().resolvedDefault
    }
}
