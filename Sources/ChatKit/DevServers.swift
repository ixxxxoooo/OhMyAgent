// @author ixxxxoooo
// 开发服务器检测(对齐 Cursor:Agent 会发现已在运行的开发服务器并复用端口,不重复启动):
// 用 `lsof` 列出本机监听的 TCP 端口,挑出像开发服务器的那些(工作目录在工作区内,或是常见的 Web 开发进程)。
// 解析是纯逻辑,便于测试;`detect` 在后台执行 lsof,带超时。

import Foundation
import OMLog

/// 一个监听中的开发服务器。
public struct DevServer: Sendable, Equatable {
    public var port: Int
    public var command: String
    public var pid: Int
    /// 进程工作目录(取不到为 nil)
    public var cwd: String?

    public init(port: Int, command: String, pid: Int, cwd: String? = nil) {
        self.port = port
        self.command = command
        self.pid = pid
        self.cwd = cwd
    }

    /// 本机访问地址。
    public var url: String { "http://localhost:\(port)" }
}

/// 开发服务器检测。
public enum DevServerDetector {
    /// 常见的 Web 开发进程名(小写,前缀匹配)。
    static let devCommands = ["node", "bun", "deno", "python", "ruby", "php", "uvicorn", "gunicorn", "flask", "rails", "puma", "java", "go", "cargo", "dotnet", "vite", "next", "webpack", "npm", "pnpm", "yarn", "hugo", "jekyll", "swift", "http-server"]
    /// 永远不是开发服务器的进程(系统服务、本应用自己、Agent)。
    static let ignoredCommands = ["controlce", "rapportd", "airplay", "sharingd", "ohmyagent", "fakeagent", "claude", "mdnsrespon", "identitys", "cupsd", "ssh", "postgres", "mysqld", "redis", "docker", "com.docker"]

    /// 解析 `lsof -nP -iTCP -sTCP:LISTEN -F pcn` 的输出。
    /// - Parameter output: lsof 的字段输出(`p<pid>` / `c<命令>` / `n<地址:端口>`)
    /// - Returns: (pid, 命令, 端口) 列表;只保留本机回环或通配地址上的监听
    static func parseListening(_ output: String) -> [(pid: Int, command: String, port: Int)] {
        var result: [(pid: Int, command: String, port: Int)] = []
        var pid = 0, command = ""
        for line in output.split(whereSeparator: \.isNewline) {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p": pid = Int(value) ?? 0
            case "c": command = value
            case "n":
                guard let colon = value.lastIndex(of: ":"), let port = Int(value[value.index(after: colon)...]) else { continue }
                let host = String(value[..<colon])
                guard host == "*" || host == "127.0.0.1" || host == "[::1]" || host == "[::]" || host == "localhost" else { continue }
                if !result.contains(where: { $0.pid == pid && $0.port == port }) { result.append((pid, command, port)) }
            default: continue
            }
        }
        return result
    }

    /// 解析 `lsof -a -p … -d cwd -F pn` 的输出为 pid → 工作目录。
    static func parseCwd(_ output: String) -> [Int: String] {
        var map: [Int: String] = [:]
        var pid = 0
        for line in output.split(whereSeparator: \.isNewline) {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            if tag == "p" { pid = Int(value) ?? 0 } else if tag == "n", pid != 0 { map[pid] = value }
        }
        return map
    }

    /// 筛选并排序:工作目录在工作区内的排最前;其余只保留常见 Web 开发进程;排除系统端口与已知非开发进程。
    /// - Parameters:
    ///   - listening: 监听列表
    ///   - cwds: pid → 工作目录
    ///   - workspace: 工作区路径
    /// - Returns: 开发服务器(最多 8 个)
    static func select(_ listening: [(pid: Int, command: String, port: Int)], cwds: [Int: String], workspace: String) -> [DevServer] {
        let root = workspace.hasSuffix("/") ? workspace : workspace + "/"
        let servers = listening.compactMap { item -> (DevServer, Bool)? in
            let name = item.command.lowercased()
            guard item.port >= 1024, !ignoredCommands.contains(where: { name.hasPrefix($0) }) else { return nil }
            let cwd = cwds[item.pid]
            let inWorkspace = cwd.map { $0 == workspace || $0.hasPrefix(root) } ?? false
            guard inWorkspace || devCommands.contains(where: { name.hasPrefix($0) }) else { return nil }
            return (DevServer(port: item.port, command: item.command, pid: item.pid, cwd: cwd), inWorkspace)
        }
        return servers.sorted { lhs, rhs in lhs.1 != rhs.1 ? lhs.1 : lhs.0.port < rhs.0.port }.prefix(8).map(\.0)
    }

    /// 检测本机正在运行的开发服务器(后台执行 lsof,最多等 3 秒)。
    /// - Parameter workspace: 工作区路径
    /// - Returns: 开发服务器;lsof 不可用或超时返回空
    public static func detect(workspace: String) async -> [DevServer] {
        await Task.detached(priority: .utility) {
            guard let listing = run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-F", "pcn"]) else { return [] }
            let listening = parseListening(listing)
            guard !listening.isEmpty else { return [] }
            let pids = Set(listening.map(\.pid)).map(String.init).joined(separator: ",")
            let cwds = run("/usr/sbin/lsof", ["-a", "-p", pids, "-d", "cwd", "-F", "pn"]).map(parseCwd) ?? [:]
            return select(listening, cwds: cwds, workspace: workspace)
        }.value
    }

    private static func run(_ path: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch {
            Log.tool.debug("启动探测进程失败", ["path": path, "error": "\(error)"])
            return nil
        }
        let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: timer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timer.cancel()
        return String(data: data, encoding: .utf8)
    }
}
