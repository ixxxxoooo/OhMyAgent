// @author ixxxxoooo
// 按项目共享的终端登记表:Agent 窗口(右栏终端标签)与 IDE 窗口(底部面板终端页)读写同一份,
// 在任一窗口新建/关闭终端,另一个窗口里同一项目的终端列表随之变化(进程由 `TerminalStore` 持有,与窗口无关)。

import Foundation
import IDEKit
import Observation

/// 按项目共享的终端登记表。
@MainActor
@Observable
final class ProjectTerminals {
    static let shared = ProjectTerminals()

    /// 一个共享终端。
    struct Entry: Equatable, Identifiable {
        /// 终端标识(与 `TerminalStore` 的键一致)
        let id: String
        /// 标题(Agent 窗口标签名)
        let title: String
        /// 所属项目根目录(已规范化);nil 表示不属于任何项目
        let project: String?
    }

    /// 全部共享终端(按创建顺序)。
    private(set) var entries: [Entry] = []

    private init() {}

    /// 项目路径规范化(Agent 与 IDE 两边的路径写法统一)。
    /// - Parameter path: 项目路径
    nonisolated static func key(_ path: String?) -> String? {
        IDEMetrics.normalizedRoot(path) ?? path
    }

    /// 全部终端标识。
    var ids: Set<String> { Set(entries.map(\.id)) }

    /// 某项目的共享终端。
    /// - Parameter project: 项目路径
    func entries(for project: String?) -> [Entry] {
        let key = Self.key(project)
        return entries.filter { $0.project == key }
    }

    /// 项目里下一个新终端的标题:「终端」「终端 2」…取最小的未被占用的编号(关掉中间的也不会重名)。
    /// Agent 窗口与 IDE 窗口新建终端都用它,两边的名字因此一致。
    /// - Parameter project: 项目路径
    func nextTitle(for project: String?) -> String {
        let base = String(localized: "终端")
        let used = Set(entries(for: project).map(\.title))
        if !used.contains(base) { return base }
        var number = 2
        while used.contains("\(base) \(number)") { number += 1 }
        return "\(base) \(number)"
    }

    /// 登记一个终端(同 id 已存在则忽略)。
    /// - Parameters:
    ///   - id: 终端标识,不能为空
    ///   - title: 标题
    ///   - project: 所属项目路径
    func add(id: String, title: String, project: String?) {
        guard !id.isEmpty, !entries.contains(where: { $0.id == id }) else { return }
        entries.append(Entry(id: id, title: title, project: Self.key(project)))
    }

    /// 移除一个终端登记(不存在则忽略;进程由调用方结束)。
    /// - Parameter id: 终端标识
    func remove(id: String) {
        entries.removeAll { $0.id == id }
    }
}
