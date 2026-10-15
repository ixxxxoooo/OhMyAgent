// @author ygw
// 更新检查:读取发布源(JSON appcast),与当前版本比较。
// 发布源格式(按通道分键,至少需要 stable):
//   { "stable": { "version": "0.2.0", "build": 12, "url": "https://…/OhMyAgent-0.2.0.dmg",
//                 "sha256": "…", "notes": "更新说明", "minimumSystemVersion": "27.0" },
//     "preview": { … } }
// 本模块只负责发现更新与提示;下载由浏览器完成(应用为 Developer ID 公证分发,未内置自替换安装器)。

import Foundation

/// 一个可用版本的描述。
public struct UpdateInfo: Codable, Sendable, Hashable {
    public var version: String
    public var build: Int?
    public var url: String
    public var sha256: String?
    public var notes: String?
    public var minimumSystemVersion: String?

    public init(version: String, build: Int? = nil, url: String, sha256: String? = nil, notes: String? = nil, minimumSystemVersion: String? = nil) {
        self.version = version; self.build = build; self.url = url
        self.sha256 = sha256; self.notes = notes; self.minimumSystemVersion = minimumSystemVersion
    }
}

/// 检查结果。
public enum UpdateResult: Sendable, Equatable {
    case upToDate
    case available(UpdateInfo)
    case unsupportedSystem(UpdateInfo)
    case failed(String)
}

/// 更新检查器。
public enum UpdateChecker {
    /// 当前系统版本字符串(如 27.0.0)。
    public static var currentSystemVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    /// 比较点分版本号(忽略非数字后缀,缺位按 0)。
    /// - Parameters:
    ///   - lhs: 版本 A
    ///   - rhs: 版本 B
    /// - Returns: A 大于 B 返回 1,小于返回 -1,相等返回 0
    public static func compare(_ lhs: String, _ rhs: String) -> Int {
        func parts(_ value: String) -> [Int] {
            value.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let a = parts(lhs), b = parts(rhs)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x > y ? 1 : -1 }
        }
        return 0
    }

    /// 解析发布源数据并与当前版本比较。
    /// - Parameters:
    ///   - data: 发布源 JSON
    ///   - channel: 通道(stable / preview);所选通道不存在时回退 stable
    ///   - currentVersion: 当前短版本号
    ///   - currentBuild: 当前构建号
    ///   - systemVersion: 当前系统版本(用于 minimumSystemVersion 判断)
    /// - Returns: 检查结果
    public static func evaluate(data: Data, channel: String, currentVersion: String, currentBuild: Int,
                                systemVersion: String = UpdateChecker.currentSystemVersion) -> UpdateResult {
        guard let feed = try? JSONDecoder().decode([String: UpdateInfo].self, from: data) else {
            return .failed("发布源格式不正确")
        }
        guard let info = feed[channel] ?? feed["stable"] else { return .failed("发布源缺少 stable 通道") }
        guard URL(string: info.url)?.scheme?.hasPrefix("http") == true else { return .failed("发布源中的下载地址无效") }
        let order = compare(info.version, currentVersion)
        let newer = order > 0 || (order == 0 && (info.build ?? 0) > currentBuild)
        guard newer else { return .upToDate }
        if let minimum = info.minimumSystemVersion, compare(systemVersion, minimum) < 0 { return .unsupportedSystem(info) }
        return .available(info)
    }

    /// 拉取发布源并检查更新。
    /// - Parameters:
    ///   - feedURL: 发布源地址(必须为 https,或本机/文件地址用于测试)
    ///   - channel: 通道
    ///   - currentVersion: 当前版本
    ///   - currentBuild: 当前构建号
    ///   - fetch: 数据获取闭包(测试可注入)
    /// - Returns: 检查结果
    public static func check(feedURL: String, channel: String, currentVersion: String, currentBuild: Int,
                             fetch: @Sendable (URL) async throws -> Data = { try await URLSession.shared.data(from: $0).0 }) async -> UpdateResult {
        let trimmed = feedURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else {
            return .failed("尚未配置更新源地址")
        }
        guard scheme == "https" || url.isFileURL || url.host == "localhost" || url.host == "127.0.0.1" else {
            return .failed("更新源必须使用 https")
        }
        do {
            let data = try await fetch(url)
            return evaluate(data: data, channel: channel, currentVersion: currentVersion, currentBuild: currentBuild)
        } catch {
            return .failed("获取更新信息失败:\(error.localizedDescription)")
        }
    }

    /// 自动检查的节流:距上次检查不足 24 小时则跳过。
    /// - Parameters:
    ///   - last: 上次检查时间
    ///   - now: 当前时间
    /// - Returns: 是否应该检查
    public static func shouldAutoCheck(last: Date?, now: Date = Date()) -> Bool {
        guard let last else { return true }
        return now.timeIntervalSince(last) >= 24 * 3600
    }
}
