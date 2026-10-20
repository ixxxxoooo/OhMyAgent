// @author ixxxxoooo
// 最近打开的文件(Files 工作区空状态的 Recents 列表):存于 UserDefaults,全局一份,读取时按项目根过滤。

import Foundation

extension RecentStore {
    static let filesKey = "recent.files"
    /// 全局最多保留的最近文件条数
    public static let maxRecentFiles = 60

    /// 记录一次文件打开(同路径去重,新的排最前)。
    /// - Parameters:
    ///   - path: 文件绝对路径(空串忽略)
    ///   - defaults: 存储
    public static func recordFile(_ path: String, _ defaults: UserDefaults = RecentStore.defaults) {
        guard !path.isEmpty else { return }
        var list = defaults.stringArray(forKey: filesKey) ?? []
        if list.first == path { return }
        list.removeAll { $0 == path }
        list.insert(path, at: 0)
        defaults.set(Array(list.prefix(maxRecentFiles)), forKey: filesKey)
    }

    /// 读取某目录(项目根)下的最近文件(新→旧)。
    /// - Parameters:
    ///   - roots: 允许的根目录(项目根与附加文件夹);为空返回空数组
    ///   - limit: 最多返回条数
    ///   - exists: 文件是否仍然存在的判定(默认检查磁盘;测试可注入)
    ///   - defaults: 存储
    public static func files(under roots: [String], limit: Int = 8,
                             exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
                             _ defaults: UserDefaults = RecentStore.defaults) -> [String] {
        guard !roots.isEmpty, limit > 0 else { return [] }
        var result: [String] = []
        for path in defaults.stringArray(forKey: filesKey) ?? [] {
            guard roots.contains(where: { path.hasPrefix($0 + "/") }), exists(path) else { continue }
            result.append(path)
            if result.count == limit { break }
        }
        return result
    }

    /// 从最近文件里移除指向某路径(含其下全部文件)的记录。
    /// - Parameters:
    ///   - path: 文件或目录绝对路径
    ///   - defaults: 存储
    public static func removeFiles(at path: String, _ defaults: UserDefaults = RecentStore.defaults) {
        guard let list = defaults.stringArray(forKey: filesKey) else { return }
        let kept = list.filter { $0 != path && !$0.hasPrefix(path + "/") }
        if kept.count != list.count { defaults.set(kept, forKey: filesKey) }
    }
}
