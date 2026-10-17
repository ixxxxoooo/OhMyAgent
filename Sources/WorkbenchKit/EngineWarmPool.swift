// @author ixxxxoooo
// 引擎预热池:提前把常用引擎连好,切换引擎时直接「认领」已就绪的待命会话,省掉启动与握手延迟。

import AgentHost
import ChatKit
import Foundation
import OMLog

/// 预热模式。
public enum WarmMode: String, CaseIterable, Sendable {
    /// 不预热(沿用按需连接)
    case off
    /// 智能:启动后延迟预热当前项目最近用过的引擎;打开引擎选择器时预热其余引擎
    case smart
    /// 全部:启动后依次预热当前项目的所有已启用引擎
    case all

    /// 偏好键。
    public static let preferenceKey = "agent.warmMode"

    /// 读取当前偏好(缺省或非法值为智能)。
    public static func current(_ defaults: UserDefaults = .standard) -> WarmMode {
        defaults.string(forKey: preferenceKey).flatMap(WarmMode.init(rawValue:)) ?? .smart
    }
}

/// 预热对象规划(纯函数,便于测试)。
public enum EngineWarmPlanner {
    /// 智能模式单次预热上限。
    public static let smartLimit = 2
    /// 全部模式 / 选择器打开时的预热上限。
    public static let allLimit = 4

    /// 计算需要预热的引擎 ID(按优先级)。
    /// - Parameters:
    ///   - mode: 预热模式
    ///   - currentEngineID: 当前会话已在使用的引擎(无需预热)
    ///   - recentEngineIDs: 当前项目最近使用的引擎(新到旧,可重复)
    ///   - enabledEngineIDs: 已启用的引擎(注册表顺序)
    /// - Returns: 需要预热的引擎 ID
    public static func plan(mode: WarmMode, currentEngineID: String?, recentEngineIDs: [String], enabledEngineIDs: [String]) -> [String] {
        let enabled = Set(enabledEngineIDs)
        switch mode {
        case .off:
            return []
        case .smart:
            var seen: Set<String> = []
            var result: [String] = []
            for id in recentEngineIDs where id != currentEngineID && enabled.contains(id) && seen.insert(id).inserted {
                result.append(id)
                if result.count >= smartLimit { break }
            }
            return result
        case .all:
            return Array(enabledEngineIDs.filter { $0 != currentEngineID }.prefix(allLimit))
        }
    }

    /// 打开引擎选择器时的预热列表:除当前引擎外的所有已启用引擎(受上限约束)。
    public static func planForPicker(mode: WarmMode, currentEngineID: String?, enabledEngineIDs: [String]) -> [String] {
        guard mode != .off else { return [] }
        return Array(enabledEngineIDs.filter { $0 != currentEngineID }.prefix(allLimit))
    }
}

/// 预热池:按「引擎 + 工作区」保存待命会话。
@MainActor
public final class EngineWarmPool {
    /// 池键。
    public struct Key: Hashable, Sendable {
        public let agentID: String
        public let workspace: String
    }

    /// 创建待命会话的工厂(应用层注入,接入通知等能力)。
    @ObservationIgnored public var factory: (@MainActor (URL, AgentDescriptor) -> SessionModel)?
    /// 同时保留的待命会话上限。
    public var capacity = 4
    /// 失败后的冷却时间:期间不再为同一键重试,避免重试风暴。
    public var failureCooldown: TimeInterval = 300

    private(set) var standby: [Key: SessionModel] = [:]
    private var failedAt: [Key: Date] = [:]
    private var warmTask: Task<Void, Never>?
    private let log = Log.session

    public init() {}

    /// 当前待命会话数量。
    public var standbyCount: Int { standby.count }

    /// 是否已有该键的待命会话(含连接中)。
    public func isWarm(agentID: String, workspace: URL) -> Bool {
        standby[Key(agentID: agentID, workspace: workspace.path)] != nil
    }

    /// 预热一个引擎:创建会话并开始连接。
    /// - Returns: 是否真的新建了待命会话
    @discardableResult
    public func warm(workspace: URL, descriptor: AgentDescriptor) -> Bool {
        guard let factory, descriptor.enabled else { return false }
        let key = Key(agentID: descriptor.id, workspace: workspace.path)
        guard standby[key] == nil, standby.count < capacity else { return false }
        if let failed = failedAt[key], Date().timeIntervalSince(failed) < failureCooldown { return false }
        let model = factory(workspace, descriptor)
        standby[key] = model
        model.connect()
        log.info("预热引擎", ["agent": descriptor.id, "cwd": workspace.path])
        return true
    }

    /// 认领待命会话:成功则移出池并交给调用方;连接已失败的会被丢弃并进入冷却。
    /// - Returns: 可直接使用的会话(可能仍在连接中)
    public func take(agentID: String, workspace: URL) -> SessionModel? {
        let key = Key(agentID: agentID, workspace: workspace.path)
        guard let model = standby.removeValue(forKey: key) else { return nil }
        if case .failed = model.phase {
            failedAt[key] = Date()
            model.shutdown()
            return nil
        }
        log.info("认领预热会话", ["agent": agentID, "cwd": workspace.path])
        return model
    }

    /// 依次预热(逐个等待上一个结束,避免同时启动多个子进程争抢 CPU)。
    /// - Parameters:
    ///   - descriptors: 按优先级排列的引擎
    ///   - workspace: 工作区
    ///   - delay: 开始前的等待(让出启动期资源)
    public func warmSequentially(_ descriptors: [AgentDescriptor], workspace: URL, delay: Duration = .seconds(3)) {
        warmTask?.cancel()
        guard !descriptors.isEmpty else { return }
        warmTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            for descriptor in descriptors {
                guard !Task.isCancelled, let self else { return }
                guard self.warm(workspace: workspace, descriptor: descriptor),
                      let model = self.standby[Key(agentID: descriptor.id, workspace: workspace.path)] else { continue }
                // 最多等 60 秒;被认领或出结果即继续下一个
                var waited = 0
                while waited < 240, !Task.isCancelled, model.phase == .connecting || model.phase == .idle {
                    try? await Task.sleep(for: .milliseconds(250))
                    waited += 1
                }
                if case .failed = model.phase {
                    self.failedAt[Key(agentID: descriptor.id, workspace: workspace.path)] = Date()
                    self.standby[Key(agentID: descriptor.id, workspace: workspace.path)] = nil
                    model.shutdown()
                }
            }
        }
    }

    /// 回收其他工作区的待命会话(切换项目时调用);`keeping` 为 nil 则全部回收。
    public func discardAll(except keeping: String? = nil) {
        warmTask?.cancel()
        for (key, model) in standby where key.workspace != keeping {
            standby[key] = nil
            model.shutdown()
        }
    }

    /// 回收指定工作区的待命会话(移除项目时调用)。
    public func discard(workspace: String) {
        for (key, model) in standby where key.workspace == workspace {
            standby[key] = nil
            model.shutdown()
        }
    }

    /// 关闭全部待命会话(应用退出时调用)。
    public func shutdownAll() {
        warmTask?.cancel()
        warmTask = nil
        for (_, model) in standby { model.shutdown() }
        standby.removeAll()
    }
}
