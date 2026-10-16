// @author ixxxxoooo
// 官方 Agent 一键安装的界面模型(目前是 Google Antigravity):检查本机安装与注册表版本、下载安装/升级/卸载,
// 安装成功后自动把 Agent 登记进 agents.json(可执行文件由安装器解析,升级后路径自动跟随)。
// 只有用户点击「安装」才会发起下载;「检查」只读取官方注册表(失败时回退内置条目)。

import AgentHost
import Foundation
import Observation
import OMLog

/// 一键安装 Agent 的状态模型(主线程)。
@MainActor
@Observable
public final class AgentInstallModel {
    public static let shared = AgentInstallModel()

    /// 操作状态。
    public enum Phase: Equatable, Sendable {
        case idle
        case checking
        case working(AgentInstallProgress)
        case failed(String)
    }

    public private(set) var phase: Phase = .idle
    /// 本机已安装的版本信息(nil = 未安装)
    public private(set) var installed: InstalledAgent?
    /// 注册表里的最新条目(未检查到时为内置回退)
    public private(set) var latest: RegistryAgent = .antigravityFallback
    /// 注册表里是否能找到当前平台的发行包
    public var platformSupported: Bool { latest.binary[ACPRegistry.currentPlatform] != nil }
    /// 是否有新版本可升级
    public var updateAvailable: Bool { installed.map { AgentInstaller.needsUpdate(installed: $0, latest: latest) } ?? false }
    /// 正在进行安装/升级
    public var isWorking: Bool {
        if case .working = phase { return true }
        return false
    }

    @ObservationIgnored private let installer: AgentInstaller
    @ObservationIgnored private let registry: AgentRegistryModel
    @ObservationIgnored private let fetchRegistry: @Sendable () async throws -> [RegistryAgent]
    @ObservationIgnored private var task: Task<Void, Never>?

    /// - Parameters:
    ///   - installer: 安装器(测试可注入临时目录与假下载器)
    ///   - registry: Agent 注册表模型
    ///   - fetchRegistry: 注册表读取(测试可注入)
    public init(installer: AgentInstaller = AgentInstaller(), registry: AgentRegistryModel = .shared,
                fetchRegistry: @escaping @Sendable () async throws -> [RegistryAgent] = { try await ACPRegistry.fetch() }) {
        self.installer = installer
        self.registry = registry
        self.fetchRegistry = fetchRegistry
        installed = installer.installed(id: AgentDescriptor.antigravity.registryId ?? "")
    }

    private var agentID: String { AgentDescriptor.antigravity.registryId ?? "antigravity-acp" }

    /// 刷新本机安装状态,并读取官方注册表确认最新版本(失败时静默回退内置条目)。
    public func refresh() {
        installed = installer.installed(id: agentID)
        guard !isWorking, phase != .checking else { return }
        phase = .checking
        let fetch = fetchRegistry
        let id = agentID
        task = Task { [weak self] in
            do {
                let agents = try await fetch()
                if let entry = agents.first(where: { $0.id == id }) { self?.latest = entry }
            } catch {
                Log.agent.warning("读取 ACP 注册表失败,使用内置条目", ["error": "\(error)"])
            }
            if self?.phase == .checking { self?.phase = .idle }
        }
    }

    /// 一键安装或升级(用户点击后才联网下载)。
    public func install() {
        guard !isWorking else { return }
        phase = .working(.downloading(0))
        let installer = installer
        let target = latest
        task = Task { [weak self] in
            do {
                let result = try await installer.install(target) { progress in
                    Task { @MainActor in if self?.isWorking == true { self?.phase = .working(progress) } }
                }
                self?.finishInstall(result)
            } catch is CancellationError {
                self?.phase = .idle
            } catch {
                Log.agent.error("Agent 安装失败", error: error, ["agent": target.id])
                self?.phase = .failed(error.localizedDescription)
            }
        }
    }

    /// 取消进行中的下载/安装。
    public func cancel() {
        task?.cancel()
        phase = .idle
    }

    /// 卸载并从注册表移除(保留用户在登记项里设置的环境变量以外的内容不再需要)。
    public func uninstall() {
        do {
            try installer.uninstall(id: agentID)
            installed = nil
            registry.remove(agentId: AgentDescriptor.antigravity.id)
            phase = .idle
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// 设置 Antigravity 的默认模型(写入 `AGY_ACP_DEFAULT_MODEL`;空串表示使用官方默认)。
    /// - Parameter model: 模型标识
    public func setDefaultModel(_ model: String) {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var descriptor = registry.data.allAgents.first(where: { $0.id == AgentDescriptor.antigravity.id }) else { return }
        if trimmed.isEmpty { descriptor.env.removeValue(forKey: AgentDescriptor.antigravityModelEnv) } else { descriptor.env[AgentDescriptor.antigravityModelEnv] = trimmed }
        registry.upsert(descriptor)
    }

    /// 当前登记的默认模型(无则空串)。
    public var defaultModel: String {
        registry.data.allAgents.first { $0.id == AgentDescriptor.antigravity.id }?.env[AgentDescriptor.antigravityModelEnv] ?? ""
    }

    /// 是否已登记到 agents.json。
    public var isRegistered: Bool { registry.data.allAgents.contains { $0.id == AgentDescriptor.antigravity.id } }

    private func finishInstall(_ result: InstalledAgent) {
        installed = result
        // 保留用户已有的环境变量与启用状态
        var descriptor = registry.data.allAgents.first { $0.id == AgentDescriptor.antigravity.id } ?? .antigravity
        descriptor.registryId = agentID
        descriptor.command = nil
        registry.upsert(descriptor)
        phase = .idle
        Log.agent.info("Antigravity 安装完成并登记", ["version": result.version])
    }
}
