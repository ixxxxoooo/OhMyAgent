// @author ixxxxoooo
// 权限选项构建:按工具类型生成「允许一次 / 始终允许 / 拒绝」选项与文案(与 Node 适配器一致)。

import ACPKit
import Foundation

/// 构建权限选项所需的上下文。
struct PermissionOptionContext {
    var toolName: String
    var displayName: String?
    var input: JSONValue
    var cwd: String
    var durableChangeSet: DurableChangeSet?
    var allowPersistentOptions = true
    var defaultToNo = false
    var availableModes: [String] = []
    var prePlanMode: String?
    var contextUsedPercent: Int?
}

/// 权限选项构建器(纯函数)。
enum PermissionOptionBuilder {
    /// 构建并按种类排序的选项列表。
    static func build(_ context: PermissionOptionContext) -> [PermissionOption] {
        let options = unsorted(context)
        return options.enumerated().sorted { lhs, rhs in
            let l = order(lhs.element, declineFirst: context.defaultToNo), r = order(rhs.element, declineFirst: context.defaultToNo)
            return l == r ? lhs.offset < rhs.offset : l < r
        }.map(\.element)
    }

    private static func order(_ option: PermissionOption, declineFirst: Bool) -> Int {
        func base(_ kind: String) -> Int {
            switch kind {
            case "allow_once": return 0
            case "allow_always": return 1
            case "reject_once", "reject_always": return 3
            default: return 2
            }
        }
        if declineFirst { return option.kind.hasPrefix("reject") ? 0 : 1 + base(option.kind) }
        return base(option.kind)
    }

    private static func unsorted(_ context: PermissionOptionContext) -> [PermissionOption] {
        if context.toolName.hasPrefix("mcp__computer-use__") { return computerUse(context) }
        switch context.toolName {
        case "Bash", "PowerShell": return shell(context)
        case "Read", "Glob", "Grep": return file(context, key: context.toolName == "Read" ? "file_path" : "path", operation: .read)
        case "Edit", "Write": return file(context, key: "file_path", operation: .write)
        case "NotebookEdit": return file(context, key: "notebook_path", operation: .write)
        case "WebFetch": return webFetch(context)
        case "Skill": return skill(context)
        case "EnterPlanMode": return [.allowOnce("Yes, enter plan mode"), .reject("No, start implementing now")]
        case "ExitPlanMode": return exitPlan(context)
        case "SandboxNetworkAccess": return sandboxNetwork(context)
        default: return fallback(context)
        }
    }

    static func plain(_ value: JSONValue?) -> String? {
        guard let text = value?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    private static func withOptionalUpdate(_ changeSet: DurableChangeSet?, _ updateName: String?, allow: String = "Yes", reject: String = "No") -> [PermissionOption] {
        var options = [PermissionOption.allowOnce(allow)]
        if changeSet != nil, let updateName { options.append(.allowWithUpdates(updateName)) }
        options.append(.reject(reject))
        return options
    }

    private static func withGeneratedUpdate(_ name: String, reject: String = "No") -> [PermissionOption] {
        [.allowOnce(), .allowWithUpdates(name), .reject(reject)]
    }

    // MARK: 文件类

    enum FileOperation { case read, write }

    private static func file(_ context: PermissionOptionContext, key: String, operation: FileOperation) -> [PermissionOption] {
        let path = plain(context.input[key]) ?? (operation == .read && key == "path" ? context.cwd : nil)
        return withOptionalUpdate(context.durableChangeSet, fileSessionLabel(context, filePath: path, operation: operation))
    }

    static func resolve(_ cwd: String, _ candidate: String) -> String {
        URL(fileURLWithPath: candidate, relativeTo: URL(fileURLWithPath: cwd, isDirectory: true)).standardized.path
    }

    static func isInside(_ directory: String, _ candidate: String) -> Bool {
        let d = URL(fileURLWithPath: directory).standardized.path, c = URL(fileURLWithPath: candidate).standardized.path
        return c == d || c.hasPrefix(d.hasSuffix("/") ? d : d + "/")
    }

    private static func isFileSessionChangeSet(_ set: DurableChangeSet, _ operation: FileOperation) -> Bool {
        set.updates.allSatisfy { update in
            guard update["destination"]?.stringValue == "session" else { return false }
            switch update["type"]?.stringValue {
            case "setMode": return operation == .write && update["mode"]?.stringValue == "acceptEdits"
            case "addDirectories": return operation == .write
            case "addRules":
                guard update["behavior"]?.stringValue == "allow" else { return false }
                return (update["rules"]?.arrayValue ?? []).allSatisfy { $0["toolName"]?.stringValue == (operation == .read ? "Read" : "Edit") }
            default: return false
            }
        }
    }

    private static func fileSessionLabel(_ context: PermissionOptionContext, filePath: String?, operation: FileOperation) -> String? {
        guard let set = context.durableChangeSet, isFileSessionChangeSet(set, operation) else { return nil }
        let resolved = filePath.map { resolve(context.cwd, $0) }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let isClaudePath = operation == .write && resolved.map {
            isInside(context.cwd + "/.claude", $0) || isInside(home + "/.claude", $0)
        } == true
        let toolName = operation == .read ? "Read" : "Edit"
        func sessionRules(broadOnly: Bool) -> Bool {
            set.updates.contains { update in
                update["type"]?.stringValue == "addRules" && update["destination"]?.stringValue == "session" && update["behavior"]?.stringValue == "allow"
                    && (update["rules"]?.arrayValue ?? []).contains { $0["toolName"]?.stringValue == toolName && (!broadOnly || $0["ruleContent"] == nil || $0["ruleContent"]?.isNull == true) }
            }
        }
        let broad = sessionRules(broadOnly: true)
        let acceptEdits = set.updates.contains { $0["type"]?.stringValue == "setMode" && $0["destination"]?.stringValue == "session" && $0["mode"]?.stringValue == "acceptEdits" }
        if let resolved {
            let covered = coversPath(set, resolved, toolName: toolName, cwd: context.cwd) || broad || (operation == .write && !isClaudePath && acceptEdits)
            if !covered { return nil }
        } else if !broad, !(operation == .write && acceptEdits) {
            return nil
        }
        if operation == .write, resolved != nil, isClaudePath, sessionRules(broadOnly: false) {
            return "Yes, and allow Claude to edit its own settings for this session"
        }
        guard let resolved, !isInside(context.cwd, resolved) else {
            return operation == .read ? "Yes, during this session" : "Yes, allow all edits during this session"
        }
        let directory = (resolved as NSString).deletingLastPathComponent
        let name = (directory as NSString).lastPathComponent.isEmpty ? "this directory" : (directory as NSString).lastPathComponent
        return operation == .read ? "Yes, allow reading from \(name)/ during this session" : "Yes, allow all edits in \(name)/ during this session"
    }

    private static func coversPath(_ set: DurableChangeSet, _ filePath: String, toolName: String, cwd: String) -> Bool {
        let directory = (filePath as NSString).deletingLastPathComponent
        var paths: [String] = []
        for update in set.updates {
            if update["type"]?.stringValue == "addDirectories" {
                paths += (update["directories"]?.arrayValue ?? []).compactMap(\.stringValue)
            } else if update["type"]?.stringValue == "addRules", update["behavior"]?.stringValue == "allow" {
                for rule in update["rules"]?.arrayValue ?? [] where rule["toolName"]?.stringValue == toolName {
                    guard var content = plain(rule["ruleContent"]) else { continue }
                    if content.hasSuffix("/**") || content.hasSuffix("\\**") { content.removeLast(3) }
                    paths.append(content)
                }
            }
        }
        return paths.contains { candidate in
            let resolved = resolve(cwd, candidate)
            return resolved == directory || isInside(resolved, filePath)
        }
    }

    // MARK: Shell

    private static func prefix(_ value: String) -> String { value.hasSuffix(":*") ? String(value.dropLast(2)) : value }

    private static func displayList(_ values: [String]) -> String {
        if values.joined(separator: ", ").count > 50 { return "similar" }
        switch values.count {
        case 0: return ""
        case 1: return values[0]
        case 2: return "\(values[0]) and \(values[1])"
        default: return values.dropLast().joined(separator: ", ") + ", and " + (values.last ?? "")
        }
    }

    private static func displayPaths(_ paths: [String]) -> String {
        var seen = Set<String>()
        let normalized = paths.map { ($0 as NSString).standardizingPath }.filter { seen.insert($0).inserted }
        let segments = normalized.map { $0.split(separator: "/").map(String.init) }
        func suffix(_ index: Int, _ depth: Int) -> String {
            let joined = segments[index].suffix(depth).joined(separator: "/")
            return joined.isEmpty ? normalized[index] : joined
        }
        let names = normalized.indices.map { index -> String in
            var name = (normalized[index] as NSString).lastPathComponent
            if name.isEmpty { name = normalized[index] }
            let count = segments[index].count
            if count > 0 {
                for depth in 1...count {
                    let candidate = suffix(index, depth)
                    if normalized.indices.allSatisfy({ $0 == index || suffix($0, depth) != candidate }) { name = candidate; break }
                    if depth == count { name = normalized[index] }
                }
            }
            return name.hasSuffix("/") ? name : name + "/"
        }
        if names.count <= 2 { return displayList(names) }
        return "\(names[0]), \(names[1]) and \(names.count - 2) more"
    }

    private static func shellLabel(_ toolName: String, _ set: DurableChangeSet) -> String? {
        let representable = set.updates.allSatisfy { update in
            if update["type"]?.stringValue == "addDirectories" { return update["destination"]?.stringValue == "session" }
            guard update["type"]?.stringValue == "addRules", update["behavior"]?.stringValue == "allow" else { return false }
            return (update["rules"]?.arrayValue ?? []).allSatisfy { ($0["toolName"]?.stringValue == toolName || $0["toolName"]?.stringValue == "Read") && plain($0["ruleContent"]) != nil }
        }
        guard representable else { return nil }
        let rules = set.addedRules
        let readPaths = rules.filter { $0["toolName"]?.stringValue == "Read" }.compactMap { rule -> String? in
            guard var content = rule["ruleContent"]?.stringValue else { return nil }
            if content.hasSuffix("/**") { content.removeLast(3) }
            return content
        }
        var commands: [String] = []
        for rule in rules where rule["toolName"]?.stringValue == toolName {
            if let content = rule["ruleContent"]?.stringValue, !content.isEmpty, !commands.contains(prefix(content)) { commands.append(prefix(content)) }
        }
        let directories = set.updates.filter { $0["type"]?.stringValue == "addDirectories" }.flatMap { ($0["directories"]?.arrayValue ?? []).compactMap(\.stringValue) }
        let hasPaths = !readPaths.isEmpty || !directories.isEmpty
        if !readPaths.isEmpty, directories.isEmpty, commands.isEmpty { return "Yes, allow reading from \(displayPaths(readPaths)) from this project" }
        if !directories.isEmpty, readPaths.isEmpty, commands.isEmpty { return "Yes, and always allow access to \(displayPaths(directories)) from this project" }
        if !commands.isEmpty, !hasPaths { return "Yes, and don't ask again for \(displayList(commands)) commands" }
        if hasPaths, commands.isEmpty { return "Yes, and always allow access to \(displayPaths(directories + readPaths)) from this project" }
        if hasPaths, !commands.isEmpty {
            let all = directories + readPaths
            return all.count == 1 && commands.count == 1
                ? "Yes, and allow access to \(displayPaths(all)) and \(displayList(commands)) commands"
                : "Yes, and allow \(displayPaths(all)) access and \(displayList(commands)) commands"
        }
        return nil
    }

    private static func shell(_ context: PermissionOptionContext) -> [PermissionOption] {
        withOptionalUpdate(context.durableChangeSet, context.durableChangeSet.flatMap { shellLabel(context.toolName, $0) })
    }

    // MARK: 其他工具

    private static func webFetch(_ context: PermissionOptionContext) -> [PermissionOption] {
        if let url = plain(context.input["url"]), context.allowPersistentOptions, let host = URL(string: url)?.host, !host.isEmpty {
            return withGeneratedUpdate("Yes, and don't ask again for \(host)")
        }
        return [.allowOnce(), .reject("No")]
    }

    private static func skill(_ context: PermissionOptionContext) -> [PermissionOption] {
        var options = [PermissionOption.allowOnce()]
        if let skill = plain(context.input["skill"]), context.allowPersistentOptions {
            options.append(.init(optionId: PermissionOptionID.allowSkillExact, name: "Yes, and don't ask again for \(skill)", kind: "allow_always"))
            if let space = skill.firstIndex(of: " "), space != skill.startIndex {
                options.append(.init(optionId: PermissionOptionID.allowSkillPrefix, name: "Yes, and don't ask again for \(skill[..<space]):* commands", kind: "allow_always"))
            }
        }
        options.append(.reject("No"))
        return options
    }

    private static func exitPlan(_ context: PermissionOptionContext) -> [PermissionOption] {
        let modes = Set(context.availableModes)
        let order = context.prePlanMode == "bypassPermissions" ? ["bypassPermissions", "auto"] : ["auto", "bypassPermissions"]
        let elevated = order.filter(modes.contains)
        let preferred = elevated.first ?? "acceptEdits"
        var options: [PermissionOption] = []
        if plain(context.input["plan"]) != nil {
            let usage = context.contextUsedPercent.map { " (\($0)% used)" } ?? ""
            switch preferred {
            case "auto": options.append(.init(optionId: PermissionOptionID.exitPlanClearAuto, name: "Yes, clear context\(usage) and use auto mode", kind: "allow_always"))
            case "bypassPermissions": options.append(.init(optionId: PermissionOptionID.exitPlanClearBypass, name: "Yes, clear context\(usage) and bypass permissions", kind: "allow_always"))
            default: options.append(.init(optionId: PermissionOptionID.exitPlanClearAcceptEdits, name: "Yes, clear context\(usage) and auto-accept edits", kind: "allow_always"))
            }
        }
        for mode in elevated {
            options.append(mode == "auto"
                ? .init(optionId: PermissionOptionID.exitPlanAuto, name: "Yes, and use auto mode", kind: "allow_always")
                : .init(optionId: PermissionOptionID.exitPlanBypass, name: "Yes, and bypass permissions", kind: "allow_always"))
        }
        if elevated.isEmpty { options.append(.init(optionId: PermissionOptionID.exitPlanAcceptEdits, name: "Yes, auto-accept edits", kind: "allow_always")) }
        options.append(.init(optionId: PermissionOptionID.exitPlanDefault, name: "Yes, manually approve edits", kind: "allow_once"))
        options.append(.reject("No, keep planning"))
        return options
    }

    private static func sandboxNetwork(_ context: PermissionOptionContext) -> [PermissionOption] {
        let host = plain(context.input["host"])
        let name = host.flatMap { context.durableChangeSet?.isExactLocalAllowRule(toolName: context.toolName, ruleContent: $0) == true ? "Yes, and don't ask again for \($0)" : nil }
        return withOptionalUpdate(context.durableChangeSet, name)
    }

    private static func fallback(_ context: PermissionOptionContext) -> [PermissionOption] {
        let label = plain(context.displayName.map { .string($0) }) ?? context.toolName
        if context.toolName.hasPrefix("mcp__") { return mcp(context, label: label, suffix: " commands") }
        if context.allowPersistentOptions { return withGeneratedUpdate("Yes, and don't ask again for \(label) commands") }
        return [.allowOnce(), .reject("No")]
    }

    private static func mcp(_ context: PermissionOptionContext, label: String, suffix: String) -> [PermissionOption] {
        let set = context.allowPersistentOptions && context.durableChangeSet?.isMcpAllow(toolName: context.toolName) == true ? context.durableChangeSet : nil
        return withOptionalUpdate(set, set == nil ? nil : "Yes, and don't ask again for \(label)\(suffix)")
    }

    private static func computerUse(_ context: PermissionOptionContext) -> [PermissionOption] {
        mcp(context, label: plain(context.displayName.map { .string($0) }) ?? context.toolName, suffix: "")
    }
}
