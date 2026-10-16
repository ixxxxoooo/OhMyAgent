// @author ixxxxoooo
// 自动化中心:持有自动化库、按 30 秒节拍调度到期任务、限制并发与单次时长、持久化到 JSON。
// 运行本身由应用层注入的 `runner` 完成(创建会话、发送提示词),本模块不依赖任何视图或 Agent 实现。

import Foundation
import Observation
import OMLog

/// 交给执行器的运行请求。
public struct AutomationRunRequest: Sendable {
    public var automation: Automation
    public var run: AutomationRun
}

/// 执行器返回的结果。
public struct AutomationRunOutcome: Sendable {
    public var status: AutomationRunStatus
    public var summary: String
    public var sessionID: String?

    public init(status: AutomationRunStatus, summary: String, sessionID: String? = nil) {
        self.status = status
        self.summary = summary
        self.sessionID = sessionID
    }
}

/// 自动化中心。
@MainActor
@Observable
public final class AutomationCenter {
    /// 全部自动化与运行记录
    public private(set) var library = AutomationLibrary()
    /// 正在运行的自动化
    public private(set) var runningIDs: Set<UUID> = []
    /// 是否已完成首次加载
    public private(set) var isLoaded = false

    /// 同时运行的上限(1...8)。
    public var maxConcurrent: Int { didSet { maxConcurrent = min(max(maxConcurrent, 1), 8) } }
    /// 单次运行的超时。
    public var runTimeout: Duration

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private let runner: @MainActor (AutomationRunRequest) async -> AutomationRunOutcome
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var cancelledRuns: Set<UUID> = []
    @ObservationIgnored private var timedOutRuns: Set<UUID> = []
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private let log = Log.app.with(["module": "automation"])

    /// 创建自动化中心。
    /// - Parameters:
    ///   - fileURL: 持久化文件
    ///   - maxConcurrent: 并发上限
    ///   - runTimeout: 单次运行超时
    ///   - calendar: 日历(测试可注入)
    ///   - now: 当前时间来源(测试可注入)
    ///   - runner: 执行器:接收请求,返回结果;应响应 Task 取消
    public init(
        fileURL: URL, maxConcurrent: Int = 2, runTimeout: Duration = .seconds(1800),
        calendar: Calendar = .current, now: @escaping @MainActor () -> Date = { Date() },
        runner: @escaping @MainActor (AutomationRunRequest) async -> AutomationRunOutcome
    ) {
        self.fileURL = fileURL
        self.maxConcurrent = min(max(maxConcurrent, 1), 8)
        self.runTimeout = runTimeout
        self.calendar = calendar
        self.now = now
        self.runner = runner
    }

    // MARK: - 加载与保存

    /// 从磁盘加载(读文件在后台线程;文件不存在视为空库,损坏则备份后重建)。
    public func load() async {
        let url = fileURL
        let result: Result<AutomationLibrary?, Error> = await Task.detached(priority: .utility) {
            do {
                guard FileManager.default.fileExists(atPath: url.path) else { return .success(nil) }
                let data = try Data(contentsOf: url)
                return .success(try Self.decoder.decode(AutomationLibrary.self, from: data))
            } catch {
                return .failure(error)
            }
        }.value
        switch result {
        case .success(let loaded):
            if let loaded { library = loaded }
        case .failure(let error):
            log.error("自动化库读取失败,已备份并重建", ["error": "\(error)"])
            let backup = fileURL.appendingPathExtension("corrupt")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: fileURL, to: backup)
        }
        // 上次异常退出时遗留的「运行中」记录标记为失败
        for run in library.runs where run.status == .running {
            var fixed = run
            fixed.status = .failed
            fixed.finishedAt = now()
            fixed.summary = String(localized: "应用退出时运行被中断")
            library.upsert(run: fixed)
        }
        isLoaded = true
        scheduleSave()
    }

    /// 合并短时间内的多次修改,后台写盘。
    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = library
        let url = fileURL
        saveTask = Task { [log] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await Task.detached(priority: .utility) {
                do {
                    let data = try Self.encoder.encode(snapshot)
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: url, options: .atomic)
                } catch {
                    log.error("自动化库写入失败", ["error": "\(error)"])
                }
            }.value
        }
    }

    /// 立即写盘(测试与退出前使用)。
    public func flush() async {
        saveTask?.cancel()
        let snapshot = library
        let url = fileURL
        await Task.detached(priority: .utility) {
            do {
                let data = try Self.encoder.encode(snapshot)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            } catch {
                Log.app.error("自动化库写入失败", ["error": "\(error)"])
            }
        }.value
    }

    private nonisolated static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private nonisolated static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    // MARK: - 增删改

    /// 新增自动化。
    /// - Returns: 校验失败时返回错误提示;成功为 nil
    @discardableResult
    public func add(_ automation: Automation) -> String? {
        if let message = automation.validationMessage() { return message }
        var item = automation
        item.baseline = now()
        library.automations.append(item)
        scheduleSave()
        log.info("新增自动化", ["id": item.id.uuidString, "name": item.name])
        return nil
    }

    /// 更新自动化(调度或启用状态变化时重置调度基准)。
    /// - Returns: 校验失败或不存在时返回错误提示;成功为 nil
    @discardableResult
    public func update(_ automation: Automation) -> String? {
        if let message = automation.validationMessage() { return message }
        guard let index = library.automations.firstIndex(where: { $0.id == automation.id }) else { return String(localized: "自动化不存在") }
        var item = automation
        let old = library.automations[index]
        item.baseline = old.baseline
        item.lastRunAt = old.lastRunAt
        if old.schedule != item.schedule || (!old.enabled && item.enabled) { item.baseline = now() }
        library.automations[index] = item
        scheduleSave()
        return nil
    }

    /// 切换启用状态。
    public func setEnabled(_ enabled: Bool, for id: UUID) {
        guard var item = library.automations.first(where: { $0.id == id }) else { return }
        item.enabled = enabled
        update(item)
    }

    /// 删除自动化(运行中的先取消)。
    public func remove(_ id: UUID) {
        cancel(automation: id)
        library.remove(automation: id)
        scheduleSave()
    }

    // MARK: - 调度

    /// 启动调度节拍(幂等);启动后立即检查一次,错过的任务补跑一次。
    /// - Parameter interval: 节拍间隔
    public func start(interval: Duration = .seconds(30)) {
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// 停止调度节拍(不影响正在运行的任务)。
    public func stop() {
        ticker?.cancel()
        ticker = nil
    }

    /// 检查并启动所有到期的自动化,受并发上限约束。
    /// - Returns: 本次启动的自动化数量
    @discardableResult
    public func tick() -> Int {
        guard isLoaded else { return 0 }
        let current = now()
        var started = 0
        for automation in library.automations where !runningIDs.contains(automation.id) && automation.isDue(now: current, calendar: calendar) {
            guard runningIDs.count < maxConcurrent else { break }
            if begin(automation, trigger: .schedule) { started += 1 }
        }
        return started
    }

    /// 立即运行一次(忽略调度与并发上限;已在运行则忽略)。
    /// - Returns: 是否启动
    @discardableResult
    public func runNow(_ id: UUID) -> Bool {
        guard let automation = library.automations.first(where: { $0.id == id }) else { return false }
        return begin(automation, trigger: .manual)
    }

    /// 取消某个自动化正在进行的运行。
    public func cancel(automation id: UUID) {
        guard let run = library.runs.first(where: { $0.automationID == id && $0.status == .running }) else { return }
        cancelledRuns.insert(run.id)
        tasks[run.id]?.cancel()
    }

    /// 正在进行的运行记录。
    public func currentRun(of id: UUID) -> AutomationRun? {
        library.runs.first { $0.automationID == id && $0.status == .running }
    }

    /// 创建运行记录并启动执行任务。
    private func begin(_ automation: Automation, trigger: AutomationTrigger) -> Bool {
        guard !runningIDs.contains(automation.id) else { return false }
        let started = now()
        let run = AutomationRun(automationID: automation.id, trigger: trigger, startedAt: started)
        library.upsert(run: run)
        if let index = library.automations.firstIndex(where: { $0.id == automation.id }) {
            library.automations[index].lastRunAt = started
            library.automations[index].baseline = started
        }
        runningIDs.insert(automation.id)
        scheduleSave()
        log.info("自动化开始运行", ["id": automation.id.uuidString, "run": run.id.uuidString, "trigger": trigger.rawValue])
        let request = AutomationRunRequest(automation: automation, run: run)
        let timeout = runTimeout
        tasks[run.id] = Task { [weak self] in
            await self?.execute(request, timeout: timeout)
        }
        return true
    }

    /// 执行并在结束后落记录;超时与取消会覆盖执行器返回的状态。
    private func execute(_ request: AutomationRunRequest, timeout: Duration) async {
        let runID = request.run.id
        let work = Task { await runner(request) }
        let guardTimer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.timedOutRuns.insert(runID)
            work.cancel()
        }
        // 外层任务被取消时转发给执行任务
        let outcome = await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
        guardTimer.cancel()
        var finished = request.run
        finished.finishedAt = now()
        finished.sessionID = outcome.sessionID
        finished.summary = outcome.summary
        if timedOutRuns.remove(runID) != nil {
            finished.status = .timedOut
        } else if cancelledRuns.remove(runID) != nil {
            finished.status = .cancelled
        } else {
            finished.status = outcome.status.isFinished ? outcome.status : .failed
        }
        // 自动化在运行期间被删除:不再落记录
        if library.automations.contains(where: { $0.id == request.automation.id }) {
            library.upsert(run: finished)
        }
        runningIDs.remove(request.automation.id)
        tasks[runID] = nil
        scheduleSave()
        let elapsed = finished.duration ?? 0
        log.info("自动化运行结束", ["id": request.automation.id.uuidString, "run": runID.uuidString, "status": finished.status.rawValue, "seconds": String(format: "%.1f", elapsed)])
    }
}

extension AutomationCenter {
    /// 仅供测试:直接写入一条运行记录(模拟上次异常退出遗留的记录)。
    func testingInsert(run: AutomationRun) {
        library.upsert(run: run)
    }
}
