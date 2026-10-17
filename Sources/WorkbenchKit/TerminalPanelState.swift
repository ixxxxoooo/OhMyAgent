// @author ixxxxoooo
// 终端面板的多终端状态(每个项目根一份):有序的终端实例、当前激活项、增删与循环切换。
// 纯值类型,无视图;进程与渲染由应用层的 `TerminalStore` 按实例 id 持有。

import Foundation

/// 终端面板里的一个终端实例。
public struct TerminalInstance: Codable, Equatable, Identifiable, Sendable {
    /// 终端标识(同时是 `TerminalStore` 的键);首个实例沿用旧版的 `bottom:{项目根}`,保证升级后进程与标签不变
    public let id: String
    /// 序号(显示为「终端 N」,关闭后不复用,避免标题重复)
    public let serial: Int
    /// 用户重命名后的标题;nil 表示用 shell 上报的标题或「终端 N」
    public var customTitle: String?

    public init(id: String, serial: Int, customTitle: String? = nil) {
        self.id = id
        self.serial = serial
        self.customTitle = customTitle
    }
}

/// 关闭终端实例的结果。
public enum TerminalCloseResult: Equatable, Sendable {
    /// 仍有终端,返回新的激活项 id
    case remaining(active: String)
    /// 关闭的是最后一个:面板应隐藏,状态已重置为全新的单实例
    case closedLast
    /// id 不存在,无变化
    case unknown
}

/// 某个项目根下的终端实例集合。
public struct TerminalPanelState: Codable, Equatable, Sendable {
    /// 项目根(用于生成实例 id)
    public let root: String
    /// 实例(按标签顺序)
    public private(set) var instances: [TerminalInstance]
    /// 当前激活的实例 id
    public private(set) var activeID: String
    /// 下一个序号
    private var nextSerial: Int

    /// 最多同时存在的终端数(防止误操作产生大量进程)
    public static let maxInstances = 12

    /// 创建只含首个终端的状态。
    /// - Parameter root: 项目根目录路径
    public init(root: String) {
        self.root = root
        let first = TerminalInstance(id: Self.baseID(root), serial: 1)
        instances = [first]
        activeID = first.id
        nextSerial = 2
    }

    /// 首个实例的标识(与旧版底部面板终端一致)。
    public static func baseID(_ root: String) -> String { "bottom:\(root)" }

    /// 当前激活的实例。
    public var active: TerminalInstance {
        instances.first { $0.id == activeID } ?? instances[0]
    }

    /// 是否还能新建终端。
    public var canAdd: Bool { instances.count < Self.maxInstances }

    /// 新建终端并激活。
    /// - Returns: 新实例;已达上限时返回 nil
    @discardableResult
    public mutating func add() -> TerminalInstance? {
        guard canAdd else { return nil }
        let serial = nextSerial
        nextSerial += 1
        let instance = TerminalInstance(id: serial == 1 ? Self.baseID(root) : "\(Self.baseID(root))#\(serial)", serial: serial)
        instances.append(instance)
        activeID = instance.id
        return instance
    }

    /// 激活指定终端(id 不存在时忽略)。
    public mutating func activate(_ id: String) {
        if instances.contains(where: { $0.id == id }) { activeID = id }
    }

    /// 按顺序循环切换激活项。
    /// - Parameter step: 步长(1 下一个,-1 上一个)
    public mutating func cycle(_ step: Int) {
        guard instances.count > 1, let index = instances.firstIndex(where: { $0.id == activeID }) else { return }
        let count = instances.count
        activeID = instances[((index + step) % count + count) % count].id
    }

    /// 关闭终端。关闭激活项时激活相邻的一个(优先右侧,其次左侧)。
    /// - Parameter id: 要关闭的实例 id
    /// - Returns: 关闭结果
    @discardableResult
    public mutating func close(_ id: String) -> TerminalCloseResult {
        guard let index = instances.firstIndex(where: { $0.id == id }) else { return .unknown }
        if instances.count == 1 {
            self = TerminalPanelState(root: root)
            return .closedLast
        }
        instances.remove(at: index)
        if activeID == id { activeID = instances[min(index, instances.count - 1)].id }
        return .remaining(active: activeID)
    }

    /// 关闭除指定终端外的所有终端。
    /// - Parameter id: 保留的实例 id
    /// - Returns: 被关闭的实例 id 列表
    @discardableResult
    public mutating func closeOthers(keeping id: String) -> [String] {
        guard instances.contains(where: { $0.id == id }) else { return [] }
        let closed = instances.filter { $0.id != id }.map(\.id)
        instances.removeAll { $0.id != id }
        activeID = id
        return closed
    }

    /// 重命名终端(空白名称恢复自动标题)。
    public mutating func rename(_ id: String, to title: String) {
        guard let index = instances.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        instances[index].customTitle = trimmed.isEmpty ? nil : String(trimmed.prefix(40))
    }

    /// 校验并修复(从磁盘读取后调用):保证至少一个实例、激活项存在、实例数不超过上限。
    public mutating func normalize() {
        if instances.isEmpty { self = TerminalPanelState(root: root); return }
        if instances.count > Self.maxInstances { instances = Array(instances.prefix(Self.maxInstances)) }
        if !instances.contains(where: { $0.id == activeID }) { activeID = instances[0].id }
        nextSerial = max(nextSerial, (instances.map(\.serial).max() ?? 0) + 1)
    }
}
