// @author ixxxxoooo
// 提交说明生成(对标 Cursor 的「生成提交信息」):
// 把待提交的补丁、文件清单和最近提交的标题一起交给小模型,让它学习本仓库的写法(语言、是否 Conventional Commits、粒度),
// 输出「标题 + 可选要点正文」;没有可用模型或请求失败时,退回到基于补丁内容的启发式生成(不再只看文件名)。
// 纯逻辑,无视图;网络请求经本机模型网关,与会话标题生成同一条通道。

import Foundation
import OMLog

/// 一个被改动的文件。
public struct CommitFileChange: Sendable, Equatable {
    /// 仓库相对路径
    public var path: String
    /// 状态字母:A 新增 / M 修改 / D 删除 / R 重命名 / ? 未跟踪
    public var status: String
    public var added: Int
    public var removed: Int

    public init(path: String, status: String, added: Int = 0, removed: Int = 0) {
        self.path = path
        self.status = status
        self.added = added
        self.removed = removed
    }
}

/// 生成提交说明的上下文。
public struct CommitContext: Sendable, Equatable {
    public var branch: String
    public var files: [CommitFileChange]
    /// 统一 diff 补丁(可能很长,生成前会精简)
    public var patch: String
    /// 最近提交的标题(新到旧),用于学习风格
    public var recentSubjects: [String]

    public init(branch: String = "", files: [CommitFileChange], patch: String, recentSubjects: [String] = []) {
        self.branch = branch
        self.files = files
        self.patch = patch
        self.recentSubjects = recentSubjects
    }
}

/// 提交说明生成器。
public enum CommitMessageGenerator {
    /// 发给模型的补丁字符预算
    public static let patchBudget = 14_000
    /// 单个文件补丁的字符上限(避免一个大文件挤掉其他文件)
    public static let perFileBudget = 3_000
    /// 标题行的建议最大长度
    public static let subjectLimit = 72

    // MARK: 材料解析

    /// 把 `--name-status` 与 `--numstat` 输出合并成文件清单。
    /// - Parameters:
    ///   - nameStatus: 每行 `状态<TAB>路径`(重命名为 `R100<TAB>旧<TAB>新`)
    ///   - numstat: 每行 `新增<TAB>删除<TAB>路径`(二进制为 `-`)
    ///   - untracked: 以补丁形式附上的未跟踪文件
    /// - Returns: 文件清单(按路径去重)
    public static func parseFiles(nameStatus: String, numstat: String, untracked: [String] = []) -> [CommitFileChange] {
        var counts: [String: (Int, Int)] = [:]
        for line in numstat.split(separator: "\n") {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count >= 3 else { continue }
            counts[String(parts[2])] = (Int(parts[0]) ?? 0, Int(parts[1]) ?? 0)
        }
        var result: [CommitFileChange] = []
        var seen: Set<String> = []
        for line in nameStatus.split(separator: "\n") {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 2 else { continue }
            let path = parts.last ?? parts[1]
            guard seen.insert(path).inserted else { continue }
            let pair = counts[path] ?? (0, 0)
            result.append(CommitFileChange(path: path, status: String(parts[0].prefix(1)), added: pair.0, removed: pair.1))
        }
        for path in untracked where seen.insert(path).inserted {
            result.append(CommitFileChange(path: path, status: "A"))
        }
        return result
    }

    // MARK: 补丁精简

    /// 噪声文件:锁文件、生成物、资源,补丁内容对写提交说明没有帮助。
    static func isNoise(_ path: String) -> Bool {
        let lower = path.lowercased()
        let name = (lower as NSString).lastPathComponent
        if ["package-lock.json", "yarn.lock", "pnpm-lock.yaml", "package.resolved", "podfile.lock", "cargo.lock", "gemfile.lock", "go.sum"].contains(name) { return true }
        if lower.hasSuffix(".min.js") || lower.hasSuffix(".svg") || lower.hasSuffix(".png") || lower.hasSuffix(".pdf") || lower.hasSuffix(".xcassets") { return true }
        if lower.contains("/generated/") || lower.contains("/vendor/") || lower.hasPrefix("vendor/") || lower.hasPrefix("build/") { return true }
        return false
    }

    /// 精简补丁:去掉噪声文件,每个文件按上限截断,总量不超过预算;文件之间保持原有顺序。
    /// - Parameters:
    ///   - patch: 完整补丁
    ///   - budget: 总字符预算
    ///   - perFile: 单文件字符上限
    /// - Returns: 精简后的补丁
    public static func condensePatch(_ patch: String, budget: Int = patchBudget, perFile: Int = perFileBudget) -> String {
        var chunks: [(path: String, text: String)] = []
        var current: [Substring] = []
        var currentPath = ""
        func flush() {
            guard !current.isEmpty else { return }
            chunks.append((currentPath, current.joined(separator: "\n")))
            current = []
        }
        for line in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("diff --git ") {
                flush()
                currentPath = line.split(separator: " ").last.map { String($0.dropFirst(2)) } ?? ""
            }
            current.append(line)
        }
        flush()
        var out = ""
        var omitted: [String] = []
        for chunk in chunks {
            if chunk.path.isEmpty && chunk.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            if isNoise(chunk.path) { omitted.append(chunk.path); continue }
            var text = chunk.text
            if text.count > perFile { text = String(text.prefix(perFile)) + "\n… (该文件改动较长,已截断)" }
            if out.count + text.count > budget { omitted.append(chunk.path); continue }
            out += text + "\n"
        }
        if !omitted.isEmpty { out += "\n(以下文件的补丁已省略:\(omitted.prefix(12).joined(separator: ", ")))\n" }
        return out
    }

    // MARK: 提示词

    /// 最近提交的标题里是否含中文(决定默认输出语言)。
    static func prefersChinese(_ subjects: [String]) -> Bool {
        let sample = subjects.prefix(6).joined()
        guard !sample.isEmpty else { return true }
        let cjk = sample.unicodeScalars.filter { (0x4E00...0x9FFF).contains($0.value) }.count
        return cjk > 0 && cjk * 10 >= sample.unicodeScalars.count
    }

    /// 最近提交是否基本遵循 Conventional Commits。
    static func usesConventional(_ subjects: [String]) -> Bool {
        let sample = subjects.prefix(8)
        guard !sample.isEmpty else { return true }
        let hits = sample.filter { subject in
            guard let colon = subject.firstIndex(where: { $0 == ":" || $0 == "\u{FF1A}" }) else { return false }
            let head = subject[..<colon]
            let type = head.split(separator: "(").first.map(String.init) ?? String(head)
            return conventionalTypes.contains(type.trimmingCharacters(in: CharacterSet(charactersIn: "!")))
        }
        return hits.count * 2 >= sample.count
    }

    static let conventionalTypes: Set<String> = ["feat", "fix", "docs", "style", "refactor", "perf", "test", "build", "ci", "chore", "revert"]

    /// 构造提示词。
    /// - Parameter context: 提交上下文
    /// - Returns: 完整的单轮提示词
    public static func prompt(for context: CommitContext) -> String {
        let chinese = prefersChinese(context.recentSubjects)
        let conventional = usesConventional(context.recentSubjects)
        let fileLines = context.files.prefix(40).map { "\($0.status) \($0.path) (+\($0.added) −\($0.removed))" }.joined(separator: "\n")
        let recent = context.recentSubjects.prefix(8).map { "- \($0)" }.joined(separator: "\n")
        var rules = [
            "你是一位资深工程师,正在为下面这次代码改动写 git 提交说明。",
            "格式:第一行是标题(不超过 \(subjectLimit) 个字符,不加句号);如改动涉及多个方面,空一行后用 2 到 5 条「- 」要点说明做了什么和为什么,每条一行。",
            "只描述这次改动的实际内容,优先写「为什么/达到什么效果」而不是罗列文件名;不要编造补丁里没有的内容。",
            "输出语言:\(chinese ? "中文(标识符和专有名词保持原样)" : "英文")。",
            conventional ? "标题使用 Conventional Commits:`type(scope): 描述`,type 取 feat/fix/refactor/docs/test/chore/perf/style/build/ci 之一,scope 取受影响的模块(可省略)。" : "标题模仿下面「最近的提交」的写法与粒度。",
            "只输出提交说明本身,不要代码块围栏、引号、解释或前缀。",
        ]
        if !context.branch.isEmpty { rules.append("当前分支:\(context.branch)") }
        var text = rules.joined(separator: "\n")
        if !recent.isEmpty { text += "\n\n本仓库最近的提交(学习其风格):\n\(recent)" }
        text += "\n\n改动文件:\n\(fileLines)"
        text += "\n\n补丁:\n\(condensePatch(context.patch))"
        return text
    }

    /// 构造 Anthropic Messages 请求体。
    /// - Parameters:
    ///   - model: 网关模型别名
    ///   - context: 提交上下文
    public static func requestBody(model: String, context: CommitContext) -> Data? {
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 400,
            "stream": false,
            "messages": [["role": "user", "content": prompt(for: context)]],
        ]
        return try? JSONSerialization.data(withJSONObject: body)
    }

    // MARK: 结果清洗

    /// 清洗模型输出:去代码围栏、整体引号、「提交说明:」前缀,压缩多余空行,标题行超长则截断。
    /// - Parameter raw: 模型原始输出
    /// - Returns: 可直接放进输入框的说明;没有有效内容返回 nil
    public static func clean(_ raw: String) -> String? {
        var lines = raw.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        lines.removeAll { $0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }
        var text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["提交说明:", "提交说明\u{FF1A}", "提交信息:", "提交信息\u{FF1A}", "Commit message:", "commit message:", "Commit Message:"] where text.hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let quotes = CharacterSet(charactersIn: "\"'“”‘’`")
        if let first = text.unicodeScalars.first, let last = text.unicodeScalars.last, quotes.contains(first), quotes.contains(last), text.count > 2 {
            text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !text.isEmpty else { return nil }
        // 压缩连续空行
        var out: [String] = []
        for line in text.components(separatedBy: "\n") {
            let trimmedTrailing = line.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
            if trimmedTrailing.isEmpty, out.last?.isEmpty ?? true { continue }
            out.append(trimmedTrailing)
        }
        guard var subject = out.first else { return nil }
        while let last = subject.last, "。.".contains(last) { subject.removeLast() }
        if subject.count > subjectLimit + 20 { subject = String(subject.prefix(subjectLimit + 17)) + "…" }
        out[0] = subject
        return out.joined(separator: "\n")
    }

    /// 从 Anthropic Messages 响应里取出文本。
    public static func responseText(from data: Data) -> String? {
        TitleGenerator.responseText(from: data)
    }

    // MARK: 网关请求

    /// 经本机模型网关生成提交说明。
    /// - Parameters:
    ///   - gateway: 网关地址
    ///   - model: 网关模型别名(通常取小模型槽位)
    ///   - context: 提交上下文
    ///   - timeout: 超时
    ///   - session: URLSession(测试可注入)
    /// - Returns: 清洗后的说明;失败返回 nil(调用方退回启发式)
    public static func generate(gateway: URL, model: String, context: CommitContext, timeout: TimeInterval = 40, session: URLSession = .shared) async -> String? {
        guard !context.files.isEmpty, let body = requestBody(model: model, context: context) else { return nil }
        var request = URLRequest(url: gateway.appendingPathComponent("v1/messages"), timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue(ProviderLaunch.placeholderToken, forHTTPHeaderField: "x-api-key")
        let started = ContinuousClock.now
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                Log.git.warning("生成提交说明失败", ["status": "\((response as? HTTPURLResponse)?.statusCode ?? -1)"])
                return nil
            }
            let message = responseText(from: data).flatMap(clean)
            Log.git.info("生成提交说明完成", ["ms": "\(OMLogger.milliseconds(since: started))", "files": "\(context.files.count)", "ok": "\(message != nil)"])
            return message
        } catch {
            Log.git.warning("生成提交说明请求出错", ["reason": error.localizedDescription])
            return nil
        }
    }

    // MARK: 启发式兜底

    /// 基于补丁内容的启发式生成(没有可用模型时使用):
    /// 按路径与补丁判断类型,按目录归纳作用域,从新增行里提取类型/函数名作为描述,并附文件要点。
    /// - Parameter context: 提交上下文
    /// - Returns: 提交说明;没有文件时为空串
    public static func heuristic(for context: CommitContext) -> String {
        let files = context.files
        guard !files.isEmpty else { return "" }
        let chinese = prefersChinese(context.recentSubjects)
        let conventional = usesConventional(context.recentSubjects)
        let type = inferType(files: files, patch: context.patch)
        let scope = inferScope(files: files)
        let symbols = addedSymbols(in: context.patch, limit: 3)
        let subject = describe(type: type, files: files, symbols: symbols, chinese: chinese)
        var head: String
        if conventional {
            head = scope.isEmpty ? "\(type): \(subject)" : "\(type)(\(scope)): \(subject)"
        } else {
            head = subject
        }
        if head.count > subjectLimit + 20 { head = String(head.prefix(subjectLimit + 17)) + "…" }
        guard files.count > 1 else { return head }
        let bullets = files.prefix(6).map { file -> String in
            let name = (file.path as NSString).lastPathComponent
            let verb: String
            switch file.status {
            case "A", "?": verb = chinese ? "新增" : "add"
            case "D": verb = chinese ? "删除" : "remove"
            case "R": verb = chinese ? "重命名" : "rename"
            default: verb = chinese ? "更新" : "update"
            }
            return "- \(verb) \(name)" + (file.added + file.removed > 0 ? " (+\(file.added) −\(file.removed))" : "")
        }
        let more = files.count > 6 ? ["- " + (chinese ? "…等共 \(files.count) 个文件" : "… and \(files.count - 6) more files")] : []
        return head + "\n\n" + (bullets + more).joined(separator: "\n")
    }

    /// 推断 Conventional Commits 的 type。
    static func inferType(files: [CommitFileChange], patch: String) -> String {
        let real = files.filter { !isNoise($0.path) }
        let pool = real.isEmpty ? files : real
        func all(_ test: (String) -> Bool) -> Bool { pool.allSatisfy { test($0.path.lowercased()) } }
        if all({ $0.contains("test") || $0.contains("spec") }) { return "test" }
        if all({ $0.hasSuffix(".md") || $0.hasPrefix("docs/") || $0.contains("/docs/") || $0.hasSuffix(".txt") }) { return "docs" }
        if all({ $0.hasPrefix(".github/") || $0.contains("ci") && $0.hasSuffix(".yml") }) { return "ci" }
        if all({ $0.hasSuffix(".json") || $0.hasSuffix(".plist") || $0.hasSuffix(".yml") || $0.hasSuffix(".yaml") || $0.hasSuffix(".toml") || $0.contains("package.swift") || $0.hasPrefix("scripts/") || $0.hasSuffix(".sh") || $0.hasSuffix(".strings") }) { return "chore" }
        let added = patch.split(separator: "\n").filter { $0.hasPrefix("+") && !$0.hasPrefix("+++") }.map { $0.lowercased() }
        let fixHits = added.filter { $0.contains("fix") || $0.contains("bug") || $0.contains("crash") || $0.contains("修复") || $0.contains("fallback") || $0.contains("guard ") }.count
        let newSources = pool.filter { ($0.status == "A" || $0.status == "?") && !$0.path.lowercased().contains("test") }.count
        if newSources > 0 && newSources * 2 >= pool.count { return "feat" }
        let totalAdded = pool.reduce(0) { $0 + $1.added }
        let totalRemoved = pool.reduce(0) { $0 + $1.removed }
        if fixHits > 0 && fixHits * 6 >= max(1, added.count) && totalAdded < 120 { return "fix" }
        if totalRemoved > totalAdded && totalRemoved > 20 { return "refactor" }
        return totalAdded >= 60 ? "feat" : "fix"
    }

    /// 推断作用域:所有文件共享的模块/目录;否则取改动最多的模块。
    static func inferScope(files: [CommitFileChange]) -> String {
        let modules = files.compactMap { file -> String? in
            let parts = file.path.split(separator: "/").map(String.init)
            if parts.count >= 3, parts[0] == "Sources" || parts[0] == "Tests" || parts[0] == "src" { return parts[1] }
            if parts.count >= 2 { return parts[0] }
            return nil
        }
        guard !modules.isEmpty else { return "" }
        let counts = Dictionary(modules.map { ($0, 1) }, uniquingKeysWith: +)
        guard let top = counts.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }) else { return "" }
        let unique = Set(modules)
        if unique.count == 1 { return top.key }
        return top.value * 2 >= modules.count ? top.key : ""
    }

    /// 取新增行里声明的类型/函数名(去重,保持出现顺序)。
    static func addedSymbols(in patch: String, limit: Int) -> [String] {
        let pattern = #"^\+\s*(?:(?:public|private|fileprivate|internal|open|static|final|nonisolated|@MainActor)\s+)*(?:func|struct|class|enum|actor|protocol|extension)\s+([A-Za-z_][A-Za-z0-9_]*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return [] }
        let range = NSRange(patch.startIndex..., in: patch)
        var seen: [String] = []
        for match in regex.matches(in: patch, range: range) where match.numberOfRanges > 1 {
            guard let r = Range(match.range(at: 1), in: patch) else { continue }
            let name = String(patch[r])
            if !seen.contains(name) { seen.append(name) }
            if seen.count >= limit { break }
        }
        return seen
    }

    /// 生成标题里的描述部分。
    private static func describe(type: String, files: [CommitFileChange], symbols: [String], chinese: Bool) -> String {
        let names = files.prefix(2).map { ($0.path as NSString).lastPathComponent }
        let target = names.joined(separator: chinese ? "、" : ", ") + (files.count > 2 ? (chinese ? " 等 \(files.count) 个文件" : " and \(files.count - 2) more") : "")
        if !symbols.isEmpty && ["feat", "refactor", "fix"].contains(type) {
            let list = symbols.joined(separator: chinese ? "、" : ", ")
            switch type {
            case "feat": return chinese ? "新增 \(list)" : "add \(list)"
            case "refactor": return chinese ? "重构 \(list)" : "refactor \(list)"
            default: return chinese ? "修复 \(list) 相关问题" : "fix issues in \(list)"
            }
        }
        switch type {
        case "docs": return chinese ? "更新文档 \(target)" : "update docs \(target)"
        case "test": return chinese ? "补充测试 \(target)" : "update tests \(target)"
        case "feat": return chinese ? "新增 \(target)" : "add \(target)"
        case "fix": return chinese ? "修复 \(target) 中的问题" : "fix issues in \(target)"
        case "refactor": return chinese ? "重构 \(target)" : "refactor \(target)"
        default: return chinese ? "更新 \(target)" : "update \(target)"
        }
    }
}
