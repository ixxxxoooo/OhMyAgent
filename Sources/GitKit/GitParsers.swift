// @author ixxxxoooo
// git 输出解析器:纯函数,便于用固定样本做单元测试。

import Foundation

public enum GitParsers {
    /// 解析 `git status --porcelain=v2 --branch -z --untracked-files=all` 的输出。
    /// - Parameter data: 命令的标准输出
    /// - Returns: 状态快照;无法识别的行会被忽略
    public static func parseStatus(_ data: Data) -> GitStatus {
        var status = GitStatus()
        let tokens = data.split(separator: 0, omittingEmptySubsequences: true).map { String(decoding: $0, as: UTF8.self) }
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            index += 1
            if token.hasPrefix("# ") {
                parseHeader(token, into: &status)
            } else if token.hasPrefix("1 ") {
                // 1 XY sub mH mI mW hH hI path
                let fields = token.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false)
                guard fields.count == 9 else { continue }
                status.changes.append(change(path: String(fields[8]), original: nil, xy: String(fields[1])))
            } else if token.hasPrefix("2 ") {
                // 2 XY sub mH mI mW hH hI Xscore path  \0 origPath
                let fields = token.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: false)
                guard fields.count == 10 else { continue }
                let original = index < tokens.count ? tokens[index] : nil
                index += 1
                status.changes.append(change(path: String(fields[9]), original: original, xy: String(fields[1])))
            } else if token.hasPrefix("u ") {
                // u XY sub m1 m2 m3 mW h1 h2 h3 path
                let fields = token.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
                guard fields.count == 11 else { continue }
                status.changes.append(GitFileChange(path: String(fields[10]), isConflicted: true))
            } else if token.hasPrefix("? ") {
                status.changes.append(GitFileChange(path: String(token.dropFirst(2)), isUntracked: true))
            }
        }
        status.changes.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return status
    }

    private static func parseHeader(_ line: String, into status: inout GitStatus) {
        let parts = line.dropFirst(2).split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return }
        let value = String(parts[1])
        switch parts[0] {
        case "branch.oid": status.headOID = value == "(initial)" ? nil : value
        case "branch.head": status.branch = value == "(detached)" ? nil : value
        case "branch.upstream": status.upstream = value
        case "branch.ab":
            for item in value.split(separator: " ") {
                if item.hasPrefix("+") { status.ahead = Int(item.dropFirst()) ?? 0 }
                if item.hasPrefix("-") { status.behind = Int(item.dropFirst()) ?? 0 }
            }
        default: break
        }
    }

    private static func change(path: String, original: String?, xy: String) -> GitFileChange {
        let chars = Array(xy)
        let staged = chars.first.flatMap(GitChangeKind.init(code:))
        let unstaged = chars.count > 1 ? GitChangeKind(code: chars[1]) : nil
        return GitFileChange(path: path, originalPath: original, staged: staged, unstaged: unstaged)
    }

    /// 解析 `git diff --numstat` 输出并求和(二进制文件计 0)。
    public static func parseNumstat(_ text: String) -> GitLineStats {
        var stats = GitLineStats()
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count >= 2 else { continue }
            stats.added += Int(fields[0]) ?? 0
            stats.removed += Int(fields[1]) ?? 0
        }
        return stats
    }

    /// 日志格式:字段以 \u{1f} 分隔,记录以 \u{1e} 结束。
    public static let logFormat = "%H%x1f%P%x1f%an%x1f%ae%x1f%at%x1f%D%x1f%s%x1e"

    /// 解析 `git log --format=<logFormat>` 输出。
    public static func parseLog(_ text: String) -> [GitCommit] {
        text.split(separator: "\u{1e}", omittingEmptySubsequences: true).compactMap { record in
            let fields = record.trimmingCharacters(in: .newlines).split(separator: "\u{1f}", maxSplits: 6, omittingEmptySubsequences: false)
            guard fields.count == 7, !fields[0].isEmpty else { return nil }
            let refs = fields[5].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return GitCommit(
                hash: String(fields[0]),
                parents: fields[1].split(separator: " ").map(String.init),
                author: String(fields[2]),
                email: String(fields[3]),
                date: Date(timeIntervalSince1970: TimeInterval(fields[4]) ?? 0),
                subject: String(fields[6]),
                refs: refs)
        }
    }

    /// 解析 `git blame --porcelain` 输出。
    public static func parseBlame(_ text: String) -> [GitBlameLine] {
        struct Meta { var author = ""; var time: TimeInterval = 0; var summary = "" }
        var cache: [String: Meta] = [:]
        var result: [GitBlameLine] = []
        var currentHash = "", currentLine = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("\t") {
                let meta = cache[currentHash] ?? Meta()
                result.append(GitBlameLine(lineNumber: currentLine, hash: currentHash, author: meta.author,
                                           date: Date(timeIntervalSince1970: meta.time), summary: meta.summary,
                                           text: String(line.dropFirst())))
                continue
            }
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: false)
            if parts.count >= 3, parts[0].count == 40, parts[0].allSatisfy(\.isHexDigit), let final = Int(parts[2]) {
                currentHash = String(parts[0])
                currentLine = final
                if cache[currentHash] == nil { cache[currentHash] = Meta() }
            } else if line.hasPrefix("author ") {
                cache[currentHash, default: Meta()].author = String(line.dropFirst(7))
            } else if line.hasPrefix("author-time ") {
                cache[currentHash, default: Meta()].time = TimeInterval(line.dropFirst(12)) ?? 0
            } else if line.hasPrefix("summary ") {
                cache[currentHash, default: Meta()].summary = String(line.dropFirst(8))
            }
        }
        return result
    }

    /// `for-each-ref` 使用的格式串。
    public static let branchFormat = "%(refname)%1f%(refname:short)%1f%(HEAD)%1f%(upstream:short)%1f%(objectname)%1f%(contents:subject)"

    /// 解析 `git for-each-ref --format=<branchFormat>` 输出;跳过 `origin/HEAD` 这类符号引用。
    public static func parseBranches(_ text: String) -> [GitBranch] {
        text.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\u{1f}", omittingEmptySubsequences: false)
            guard fields.count >= 5 else { return nil }
            let full = String(fields[0])
            let isRemote = full.hasPrefix("refs/remotes/")
            if isRemote, full.hasSuffix("/HEAD") { return nil }
            return GitBranch(name: String(fields[1]), isCurrent: fields[2] == "*", isRemote: isRemote,
                             upstream: fields[3].isEmpty ? nil : String(fields[3]), hash: String(fields[4]),
                             subject: fields.count > 5 ? String(fields[5]) : "")
        }
    }

    /// 解析 `git stash list --format=%gd%x1f%gs`。
    public static func parseStashes(_ text: String) -> [GitStash] {
        text.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\u{1f}", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2, fields[0].hasPrefix("stash@{"),
                  let close = fields[0].firstIndex(of: "}"),
                  let index = Int(fields[0][fields[0].index(fields[0].startIndex, offsetBy: 7)..<close]) else { return nil }
            return GitStash(index: index, message: String(fields[1]))
        }
    }

    /// 解析 `git show --name-status --format= -z <hash>` / `diff-tree` 的 name-status 输出(\0 分隔)。
    public static func parseNameStatus(_ data: Data) -> [GitFileChange] {
        let tokens = data.split(separator: 0, omittingEmptySubsequences: true).map { String(decoding: $0, as: UTF8.self) }
        var result: [GitFileChange] = []
        var index = 0
        while index < tokens.count {
            let code = tokens[index]
            index += 1
            guard let first = code.first, let kind = GitChangeKind(code: first) else { continue }
            if kind == .renamed || kind == .copied {
                guard index + 1 < tokens.count else { break }
                result.append(GitFileChange(path: tokens[index + 1], originalPath: tokens[index], staged: kind))
                index += 2
            } else {
                guard index < tokens.count else { break }
                result.append(GitFileChange(path: tokens[index], staged: kind))
                index += 1
            }
        }
        return result
    }
}
