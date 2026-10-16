// @author ygw
// 演示仓库生成用的 git 封装:固定作者与时间,屏蔽用户全局配置与仓库定位类环境变量,保证每次生成结果一致。

import Foundation

/// 生成演示数据时的错误。
public enum DemoError: Error, LocalizedError, Equatable {
    case gitFailed(arguments: [String], status: Int32, output: String)
    case ioFailed(String)

    public var errorDescription: String? {
        switch self {
        case .gitFailed(let arguments, let status, let output):
            return "git \(arguments.joined(separator: " ")) 失败(\(status)):\(output)"
        case .ioFailed(let message):
            return message
        }
    }
}

/// 提交作者。
struct DemoAuthor: Sendable {
    let name: String
    let email: String

    static let lin = DemoAuthor(name: "林雨", email: "yu@atlas.dev")
    static let chen = DemoAuthor(name: "陈墨", email: "mo@atlas.dev")
    static let wen = DemoAuthor(name: "Wen Jiao", email: "wj@atlas.dev")
}

/// git 命令执行器。
enum DemoGit {
    /// 固定的起始时间:2026-09-01 10:00(+08:00)。
    static let baseDate = Date(timeIntervalSince1970: 1_788_228_000)

    /// 基础时间之后若干天、若干小时的时间点。
    /// - Parameters:
    ///   - day: 天数偏移
    ///   - hour: 小时偏移
    static func date(day: Int, hour: Int = 0) -> Date {
        baseDate.addingTimeInterval(TimeInterval(day * 86_400 + hour * 3_600))
    }

    /// 隔离后的环境:不读用户/系统 git 配置,清掉仓库定位变量。
    /// - Parameter home: 作为 HOME 的目录
    static func environment(home: URL) -> [String: String] {
        var env = ProcessInfo.processInfo.environment.filter { key, _ in !key.hasPrefix("GIT_") && !key.hasPrefix("OMA_") }
        env["HOME"] = home.path
        env["GIT_CONFIG_GLOBAL"] = "/dev/null"
        env["GIT_CONFIG_NOSYSTEM"] = "1"
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_EDITOR"] = "true"
        env["LC_ALL"] = "C"
        return env
    }

    /// 运行 git。
    /// - Parameters:
    ///   - arguments: 参数(不含 `git`)
    ///   - directory: 工作目录
    ///   - environment: 额外环境变量(覆盖基础环境)
    ///   - home: 隔离用的 HOME
    ///   - allowFailure: 允许非零退出(如制造合并冲突)
    /// - Returns: 标准输出
    @discardableResult
    static func run(_ arguments: [String], in directory: URL, environment: [String: String] = [:], home: URL, allowFailure: Bool = false) async throws -> String {
        var env = Self.environment(home: home)
        for (key, value) in environment { env[key] = value }
        let result: (status: Int32, output: String) = try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = arguments
            process.currentDirectoryURL = directory
            process.environment = env
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }.value
        if result.status != 0, !allowFailure {
            throw DemoError.gitFailed(arguments: arguments, status: result.status, output: result.output)
        }
        return result.output
    }
}

/// 演示仓库构建器:写文件、提交、分支、暂存,全部使用固定身份与时间。
struct DemoRepoBuilder {
    let directory: URL
    let home: URL

    /// 初始化仓库(默认分支 main)。
    func initialize() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try await git(["init", "-q", "-b", "main"])
        try await git(["config", "user.name", DemoAuthor.wen.name])
        try await git(["config", "user.email", DemoAuthor.wen.email])
        try await git(["config", "commit.gpgsign", "false"])
        try await git(["config", "core.quotepath", "false"])
    }

    @discardableResult
    func git(_ arguments: [String], environment: [String: String] = [:], allowFailure: Bool = false) async throws -> String {
        try await DemoGit.run(arguments, in: directory, environment: environment, home: home, allowFailure: allowFailure)
    }

    /// 写入文本文件(自动创建父目录)。
    func write(_ relative: String, _ text: String) throws {
        let url = directory.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do { try text.write(to: url, atomically: true, encoding: .utf8) } catch { throw DemoError.ioFailed("写入 \(relative) 失败:\(error.localizedDescription)") }
    }

    /// 写入二进制文件。
    func write(_ relative: String, data: Data) throws {
        let url = directory.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do { try data.write(to: url, options: .atomic) } catch { throw DemoError.ioFailed("写入 \(relative) 失败:\(error.localizedDescription)") }
    }

    /// 删除文件(工作区)。
    func remove(_ relative: String) throws {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(relative))
    }

    /// 暂存全部并以固定作者与时间提交。
    /// - Parameters:
    ///   - message: 提交信息
    ///   - author: 作者
    ///   - date: 提交时间
    func commit(_ message: String, by author: DemoAuthor, at date: Date) async throws {
        try await git(["add", "-A"])
        try await git(["commit", "-q", "-m", message], environment: Self.identity(author, date))
    }

    /// 带固定身份与时间的合并(不快进)。
    func merge(_ branch: String, message: String, by author: DemoAuthor, at date: Date) async throws {
        try await git(["merge", "-q", "--no-ff", "-m", message, branch], environment: Self.identity(author, date))
    }

    /// 附注标签。
    func tag(_ name: String, message: String, by author: DemoAuthor, at date: Date) async throws {
        try await git(["tag", "-a", name, "-m", message], environment: Self.identity(author, date))
    }

    /// 固定作者/提交者与时间的环境变量。
    static func identity(_ author: DemoAuthor, _ date: Date) -> [String: String] {
        let stamp = "\(Int(date.timeIntervalSince1970)) +0800"
        return [
            "GIT_AUTHOR_NAME": author.name, "GIT_AUTHOR_EMAIL": author.email, "GIT_AUTHOR_DATE": stamp,
            "GIT_COMMITTER_NAME": author.name, "GIT_COMMITTER_EMAIL": author.email, "GIT_COMMITTER_DATE": stamp,
        ]
    }
}
