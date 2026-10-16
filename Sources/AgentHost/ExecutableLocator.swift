// @author ixxxxoooo
// 定位 node、claude 与 claude-agent-acp 适配器。

import Foundation

/// 定位结果。
public struct LocatedTools: Sendable, Hashable {
    public var nodePath: String?
    public var nodeVersion: String?
    public var claudePath: String?
    public var adapterEntry: String?
    /// 用于启动子进程的环境(已合并登录 shell 环境)
    public var environment: [String: String]

    /// 是否具备以 ACP 方式启动 Claude Code 的全部条件。
    public var isACPReady: Bool { nodePath != nil && adapterEntry != nil }
}

/// 可执行文件定位器。
public enum ExecutableLocator {
    /// Node 最低版本要求(适配器要求 >=22)。
    public static let minimumNodeMajor = 22

    /// 按优先级探测工具。
    /// - Parameters:
    ///   - overrides: 用户在“高级”设置中指定的路径(键:node / claude / adapter)
    ///   - projectRoot: 开发期的工程根目录,用于查找 Vendor/acp
    ///   - environment: 已解析的登录 shell 环境
    /// - Returns: 定位结果
    public static func locate(
        overrides: [String: String] = [:],
        projectRoot: String? = nil,
        environment: [String: String]
    ) -> LocatedTools {
        let fm = FileManager.default
        let path = environment["PATH"] ?? ""
        let pathDirs = path.split(separator: ":").map(String.init)
        let home = environment["HOME"] ?? NSHomeDirectory()

        // 1. node:覆盖 > PATH > nvm 最新 >=22 > 常见目录
        var nodeCandidates: [String] = []
        if let value = overrides["node"] { nodeCandidates.append(value) }
        nodeCandidates += pathDirs.map { "\($0)/node" }
        nodeCandidates += nvmNodes(home: home)
        nodeCandidates += ["/opt/homebrew/bin/node", "/usr/local/bin/node"]
        var nodePath: String?
        var nodeVersion: String?
        for candidate in nodeCandidates where fm.isExecutableFile(atPath: candidate) {
            if let version = version(of: candidate), majorVersion(version) >= minimumNodeMajor {
                nodePath = candidate
                nodeVersion = version
                break
            }
        }

        // 2. claude
        var claudeCandidates: [String] = []
        if let value = overrides["claude"] { claudeCandidates.append(value) }
        claudeCandidates += pathDirs.map { "\($0)/claude" }
        claudeCandidates += ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        let claudePath = claudeCandidates.first { fm.isExecutableFile(atPath: $0) }

        // 3. 适配器入口脚本
        let relative = "node_modules/@agentclientprotocol/claude-agent-acp/dist/index.js"
        var adapterCandidates: [String] = []
        if let value = overrides["adapter"] { adapterCandidates.append(value) }
        if let bundled = Bundle.main.resourcePath { adapterCandidates.append("\(bundled)/acp/\(relative)") }
        adapterCandidates.append("\(home)/Library/Application Support/OhMyAgent/acp/\(relative)")
        if let projectRoot { adapterCandidates.append("\(projectRoot)/Vendor/acp/\(relative)") }
        adapterCandidates += globalNpmRoots(nodePath: nodePath, home: home).map { "\($0)/@agentclientprotocol/claude-agent-acp/dist/index.js" }
        let adapter = adapterCandidates.first { fm.isReadableFile(atPath: $0) }

        return LocatedTools(
            nodePath: nodePath,
            nodeVersion: nodeVersion,
            claudePath: claudePath,
            adapterEntry: adapter,
            environment: environment
        )
    }

    /// 读取 nvm 已安装的 node,按版本从新到旧排序。
    static func nvmNodes(home: String) -> [String] {
        let root = "\(home)/.nvm/versions/node"
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: root) else { return [] }
        return items
            .sorted { compareVersions($0, $1) > 0 }
            .map { "\(root)/\($0)/bin/node" }
    }

    /// 可能的全局 npm 模块目录。
    static func globalNpmRoots(nodePath: String?, home: String) -> [String] {
        var roots: [String] = []
        if let nodePath {
            let bin = (nodePath as NSString).deletingLastPathComponent
            roots.append((bin as NSString).deletingLastPathComponent + "/lib/node_modules")
        }
        roots += ["/opt/homebrew/lib/node_modules", "/usr/local/lib/node_modules"]
        return roots
    }

    /// 执行 `node --version`。
    static func version(of node: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: node)
        process.arguments = ["--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// 解析 `v22.18.0` 的主版本号。
    static func majorVersion(_ version: String) -> Int {
        let trimmed = version.hasPrefix("v") ? String(version.dropFirst()) : version
        return Int(trimmed.split(separator: ".").first ?? "") ?? 0
    }

    /// 比较两个 `v22.18.0` 版本,返回 -1/0/1。
    static func compareVersions(_ lhs: String, _ rhs: String) -> Int {
        func parts(_ s: String) -> [Int] {
            (s.hasPrefix("v") ? String(s.dropFirst()) : s).split(separator: ".").map { Int($0) ?? 0 }
        }
        let a = parts(lhs), b = parts(rhs)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y ? 1 : -1 }
        }
        return 0
    }
}
