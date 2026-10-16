// @author ixxxxoooo
// Bundle ID 变更后的偏好迁移:把旧域(`com.ygw.OhMyAgent`)里的客户端设置一次性复制到当前域。

import Foundation
import OMLog

/// 旧 Bundle ID 偏好域迁移器。
///
/// 应用 Bundle ID 由 `com.ygw.OhMyAgent` 改为 `com.ixxxxoooo.OhMyAgent` 后,
/// `UserDefaults.standard` 指向全新的偏好域,外观、快捷键、语言等用户设置会"丢失"。
/// 本迁移在首次启动时把旧域内容复制过来(不覆盖新域已有的键),并写入标记保证只执行一次。
public enum LegacyDefaultsMigration {
    /// 旧版 Bundle ID(仅用于迁移读取)。
    public static let legacyDomain = "com.ygw.OhMyAgent"
    /// 迁移完成标记键。
    public static let markerKey = "migration.bundleIdentifier.ixxxxoooo"
    /// 不迁移的键前缀:系统为状态栏图标写入的可见性/位置键与旧域绑定,复制后可能导致图标被隐藏。
    static let skippedPrefixes = ["NSStatusItem"]

    /// 执行迁移。
    /// - Parameters:
    ///   - defaults: 目标偏好(默认 `.standard`)
    ///   - domain: 目标偏好域名;只检查该域内是否已有同名键(`object(forKey:)` 会读到全局域,如 `AppleLanguages`,会误判为已存在)
    ///   - legacyDomain: 旧偏好域名(测试可注入)
    ///   - legacyValues: 旧域内容读取器(测试可注入;默认读取系统持久域)
    /// - Returns: 本次迁移复制的键数量;已迁移过或旧域为空时返回 0
    @discardableResult
    public static func migrateIfNeeded(
        defaults: UserDefaults = .standard,
        domain: String = Bundle.main.bundleIdentifier ?? "",
        legacyDomain: String = LegacyDefaultsMigration.legacyDomain,
        legacyValues: (String) -> [String: Any]? = { UserDefaults.standard.persistentDomain(forName: $0) }
    ) -> Int {
        guard !legacyDomain.isEmpty, !defaults.bool(forKey: markerKey) else { return 0 }
        defaults.set(true, forKey: markerKey)
        guard let values = legacyValues(legacyDomain), !values.isEmpty else { return 0 }
        let existing = defaults.persistentDomain(forName: domain) ?? [:]
        var copied = 0
        for (key, value) in values where existing[key] == nil {
            if skippedPrefixes.contains(where: { key.hasPrefix($0) }) { continue }
            defaults.set(value, forKey: key)
            copied += 1
        }
        Log.app.info("已从旧 Bundle ID 迁移偏好", ["legacyDomain": legacyDomain, "copied": "\(copied)"])
        return copied
    }
}
