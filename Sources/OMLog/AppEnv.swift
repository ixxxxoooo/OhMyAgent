// @author ixxxxoooo
// 运行身份:区分稳定版与开发版,为数据目录、日志目录提供统一入口,使两者互不污染。

import Foundation

/// 应用运行身份(稳定版 / 开发版)。
///
/// 开发版由 `Scripts/bundle.sh dev` 生成,Bundle ID 以 `.dev` 结尾;也可用环境变量 `OMA_DEV=1` 强制(调试用)。
/// 开发版的 Application Support 与日志目录带 `-Dev` 后缀,首次启动时从稳定版复制一份(之后各自独立)。
public enum AppEnv {
    /// 稳定版数据目录名
    public static let stableFolderName = "OhMyAgent"
    /// 开发版数据目录名
    public static let devFolderName = "OhMyAgent-Dev"

    /// 是否为开发版。
    /// - Parameters:
    ///   - bundleIdentifier: 应用 Bundle ID(测试可注入)
    ///   - environment: 环境变量(测试可注入)
    /// - Returns: 开发版为 true
    public static func isDev(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        if environment["OMA_DEV"] == "1" { return true }
        return bundleIdentifier?.hasSuffix(".dev") == true
    }

    /// 当前身份对应的数据目录名。
    public static var folderName: String { isDev() ? devFolderName : stableFolderName }

    /// 系统 Application Support 根目录(随 `CFFIXED_USER_HOME` 重定向,演示模式下落入沙盒)。
    private static var applicationSupportRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
    }

    /// 当前身份的数据目录:`~/Library/Application Support/OhMyAgent[-Dev]`。
    public static var supportDirectory: URL {
        applicationSupportRoot.appendingPathComponent(folderName, isDirectory: true)
    }

    /// 当前身份的日志目录:`~/Library/Logs/OhMyAgent[-Dev]`。
    public static var logsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/\(folderName)", isDirectory: true)
    }

    /// 稳定版的偏好域(开发版首次启动时从这里复制)
    public static let stableDefaultsDomain = "com.ixxxxoooo.OhMyAgent"
    /// 开发版偏好已从稳定版复制的标记键
    static let defaultsSeededKey = "oma.dev.defaultsSeeded"

    /// 开发版首次启动:把稳定版的数据目录与偏好各复制一份;已复制过或稳定版不存在时不做任何事。
    ///
    /// 只复制不回写,开发版的任何改动都不会影响稳定版。必须在读取任何数据与偏好之前调用。
    /// - Returns: 实际复制了数据目录时为 true
    @discardableResult
    public static func seedDevDataIfNeeded() -> Bool {
        guard isDev() else { return false }
        seedDevDefaultsIfNeeded()
        let fm = FileManager.default
        let source = applicationSupportRoot.appendingPathComponent(stableFolderName, isDirectory: true)
        let target = supportDirectory
        guard !fm.fileExists(atPath: target.path), fm.fileExists(atPath: source.path) else { return false }
        do {
            try fm.copyItem(at: source, to: target)
            return true
        } catch {
            // 复制失败时退化为全新空白的开发版数据,不阻断启动
            try? fm.createDirectory(at: target, withIntermediateDirectories: true)
            return false
        }
    }

    /// 把稳定版偏好域的键复制到当前(开发版)偏好,不覆盖已有键,只执行一次。
    /// - Parameters:
    ///   - defaults: 目标偏好(测试可注入)
    ///   - stableValues: 稳定版偏好内容读取器(测试可注入)
    /// - Returns: 复制的键数量
    @discardableResult
    static func seedDevDefaultsIfNeeded(
        defaults: UserDefaults = .standard,
        stableValues: () -> [String: Any]? = { UserDefaults.standard.persistentDomain(forName: stableDefaultsDomain) }
    ) -> Int {
        guard !defaults.bool(forKey: defaultsSeededKey) else { return 0 }
        defaults.set(true, forKey: defaultsSeededKey)
        guard let values = stableValues() else { return 0 }
        var copied = 0
        for (key, value) in values where defaults.object(forKey: key) == nil {
            // 状态栏图标的可见性/位置键与 Bundle ID 绑定,复制会导致图标被隐藏
            if key.hasPrefix("NSStatusItem") { continue }
            defaults.set(value, forKey: key)
            copied += 1
        }
        return copied
    }
}
