// @author ixxxxoooo
// 工作台的会话驻留:定时按 `SessionResidencyPolicy` 休眠闲置会话,系统内存紧张时收紧上限。

import ChatKit
import Foundation
import OMLog

extension WorkbenchModel {
    private var log: OMLogger { Log.session }

    /// 检查间隔(秒)。
    static let residencyInterval: Duration = .seconds(30)

    /// 当前正显示的会话键:每个标签组的激活会话标签 + 停靠在面板里的会话。
    func visibleConversationKeys() -> Set<ConversationKey> {
        var keys: Set<ConversationKey> = []
        for group in dock.groups {
            if let active = group.active, case .chat(let projectID, let slot) = active.kind {
                keys.insert(ConversationKey(projectID: projectID, slot: slot))
            }
        }
        return keys
    }

    /// 按驻留策略休眠闲置会话,并刷新可见会话的最近使用时间。
    /// - Parameter now: 当前时间(测试可注入)
    /// - Returns: 本次休眠的会话数
    @discardableResult
    public func enforceResidency(now: Date = Date()) -> Int {
        let visible = visibleConversationKeys()
        // 总开关关闭:仍刷新可见会话的使用时间,但不休眠任何会话
        let enabled = ClientPrefs.hibernateEnabled()
        var byID: [String: SessionModel] = [:]
        var candidates: [ResidencyCandidate] = []
        for (key, model) in conversations {
            let isVisible = visible.contains(key)
            if isVisible { model.touch() }
            let id = model.uid
            byID[id] = model
            candidates.append(ResidencyCandidate(
                id: id,
                isLive: model.phase == .ready || model.phase == .connecting,
                canHibernate: model.canHibernate,
                isVisible: isVisible,
                lastUsedAt: model.lastUsedAt
            ))
        }
        guard enabled else {
            for (key, model) in conversations where visible.contains(key) { model.touch() }
            return 0
        }
        let pressure = underMemoryPressure && ClientPrefs.hibernateUnderPressure()
        var limits = residencyLimits()
        if pressure { limits = limits.underPressure }
        // 待命(预热)会话也占着进程:并入上限,先回收它们
        let standby = warmPool.standbyCount
        let victims = SessionResidencyPolicy.victims(candidates: candidates, limits: limits, now: now)
        var count = 0
        for id in victims {
            if byID[id]?.hibernate() == true { count += 1 }
        }
        if pressure, standby > 0 { warmPool.discardAll(except: nil) }
        if count > 0 {
            log.info("休眠闲置会话", ["count": "\(count)", "total": "\(conversations.count)", "pressure": pressure ? "yes" : "no"])
        }
        return count
    }

    /// 启动驻留监视(幂等):定时检查 + 监听系统内存压力。
    public func startResidencyMonitor() {
        guard residencyTask == nil else { return }
        residencyTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.residencyInterval)
                self?.enforceResidency()
            }
        }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical, .normal], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            MainActor.assumeIsolated {
                let event = source.data
                self.underMemoryPressure = event.contains(.warning) || event.contains(.critical)
                self.log.info("系统内存压力变化", ["pressure": self.underMemoryPressure ? "high" : "normal"])
                if self.underMemoryPressure { self.enforceResidency() }
            }
        }
        source.resume()
        memoryPressureSource = source
    }

    /// 停止驻留监视。
    func stopResidencyMonitor() {
        residencyTask?.cancel()
        residencyTask = nil
        memoryPressureSource?.cancel()
        memoryPressureSource = nil
    }
}
