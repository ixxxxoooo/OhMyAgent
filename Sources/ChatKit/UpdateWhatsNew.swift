// @author ixxxxoooo
// 更新完成后的「新版本说明」:退出前记下版本与说明,重启后若当前版本已追上就弹窗展示一次。

import Foundation

/// 待展示的新版本说明。
public struct WhatsNew: Codable, Sendable, Equatable {
    public var version: String
    public var notes: String?

    private static let key = "update.whatsNew"

    /// 记录即将安装的版本说明(写入 UserDefaults,更新脚本不会清掉它)。
    /// - Parameters:
    ///   - version: 目标版本
    ///   - notes: 发布说明(分号分隔的条目)
    ///   - defaults: 存储(测试可注入)
    public static func remember(version: String, notes: String?, defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(WhatsNew(version: version, notes: notes)) else { return }
        defaults.set(data, forKey: key)
    }

    /// 取出并清除待展示的说明:仅当当前版本已不低于记录的版本时返回(更新失败时保留,下次成功后再展示)。
    /// - Parameters:
    ///   - currentVersion: 当前短版本号
    ///   - defaults: 存储(测试可注入)
    /// - Returns: 需要展示的说明;没有则 nil
    public static func takePending(currentVersion: String, defaults: UserDefaults = .standard) -> WhatsNew? {
        guard let data = defaults.data(forKey: key), let value = try? JSONDecoder().decode(WhatsNew.self, from: data) else { return nil }
        guard UpdateChecker.compare(currentVersion, value.version) >= 0 else { return nil }
        defaults.removeObject(forKey: key)
        return value
    }

    /// 把「条目;条目」格式的说明整理成项目符号列表,最多 `limit` 条。
    /// - Parameters:
    ///   - notes: 原始说明
    ///   - limit: 最多显示条数
    /// - Returns: 多行文本;没有内容返回空串
    public static func bulletList(_ notes: String?, limit: Int = 12) -> String {
        let items = (notes ?? "").split(whereSeparator: { $0 == ";" || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let shown = items.prefix(limit).map { "• " + $0 }
        let more = items.count > limit ? ["…"] : []
        return (shown + more).joined(separator: "\n")
    }
}
