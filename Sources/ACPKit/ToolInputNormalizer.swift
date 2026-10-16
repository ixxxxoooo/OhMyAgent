// @author ixxxxoooo
// 工具入参/出参归一化:不同 ACP Agent 对同一类工具使用不同的字段形态,这里统一成 Claude Code 风格,
// 让下游(工具行摘要、点击展开、Diff 回退、搜索结果)无需逐个适配。
//
// 已知差异(以 Google Antigravity `agy_acp_server` 1.4 实测为准):
// - `rawInput` 在历史回放里是「JSON 字符串」,实时流里是对象;
// - 键名风格不一致:回放用 `CommandLine`/`AbsolutePath`/`TargetFile`,实时流用 `command_line`/`absolute_path`/`target_file`;
// - 行号是浮点数(`1.0`);
// - 终端结果在 `rawOutput.combinedOutput`,读取/编辑类结果为空串,失败时 `rawOutput` 是一段纯文本错误。

import Foundation

/// 工具入参/出参归一化。
public enum ToolInputNormalizer {
    /// 归一化后的规范键 ← 各 Agent 的别名(靠前优先)。规范键已存在时不覆盖。
    static let aliases: [(canonical: String, keys: [String])] = [
        ("command", ["CommandLine", "command_line", "commandLine"]),
        ("file_path", ["AbsolutePath", "absolute_path", "TargetFile", "target_file", "FilePath", "filePath"]),
        ("path", ["DirectoryPath", "directory_path", "SearchPath", "search_path", "SearchDirectory", "search_directory"]),
        ("old_string", ["TargetContent", "target_content"]),
        ("new_string", ["ReplacementContent", "replacement_content", "CodeContent", "code_content"]),
        ("pattern", ["Pattern"]),
        ("query", ["Query"]),
        ("url", ["Url", "URL"]),
        ("description", ["Description"]),
        ("start_line", ["StartLine"]),
        ("end_line", ["EndLine"]),
        ("cwd", ["Cwd", "working_dir", "workingDir"]),
    ]

    /// 归一化 `rawInput`:字符串形态的 JSON 对象先解析,再补齐规范键。
    /// - Parameter raw: 协议里的原始入参
    /// - Returns: 归一化结果;`nil`/`null` 返回 nil,无法解析的字符串原样返回
    public static func normalize(_ raw: JSONValue?) -> JSONValue? {
        guard var value = raw, !value.isNull else { return nil }
        if case .string(let text) = value {
            guard let parsed = parseObject(text) else { return value }
            value = parsed
        }
        guard case .object(var object) = value else { return value }
        for (canonical, keys) in aliases where object[canonical] == nil {
            for key in keys {
                if let found = object[key], !found.isNull {
                    object[canonical] = found
                    break
                }
            }
        }
        return .object(object)
    }

    /// 合并增量更新里的入参:两边都是对象时按键合并(新值覆盖旧值),否则以新值为准。
    /// - Parameters:
    ///   - existing: 已有入参
    ///   - update: 更新里的入参
    /// - Returns: 合并并归一化后的入参
    public static func merge(_ existing: JSONValue?, with update: JSONValue) -> JSONValue? {
        guard let incoming = normalize(update) else { return existing }
        guard case .object(let old)? = existing, case .object(let new) = incoming else { return incoming }
        return normalize(.object(old.merging(new) { _, fresh in fresh }))
    }

    /// 解析 JSON 对象文本。
    private static func parseObject(_ text: String) -> JSONValue? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(JSONValue.self, from: data), parsed.objectValue != nil else { return nil }
        return parsed
    }

    // MARK: - 出参

    /// 从 `rawOutput` 提取可展示的结果文本(终端合并输出、stdout/stderr、纯文本)。
    /// - Parameter raw: 协议里的原始出参
    /// - Returns: 非空文本;没有可展示内容返回 nil
    public static func resultText(from raw: JSONValue?) -> String? {
        guard let raw else { return nil }
        let text: String?
        switch raw {
        case .string(let value):
            text = value
        case .object(let object):
            text = ["combinedOutput", "formatted_output", "output", "stdout", "text", "result"].lazy
                .compactMap { object[$0]?.stringValue }
                .first { !$0.isEmpty }
                ?? joinedStreams(object)
        default:
            text = nil
        }
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    /// stdout 与 stderr 分开给出时拼接。
    private static func joinedStreams(_ object: [String: JSONValue]) -> String? {
        let parts = ["stdout", "stderr"].compactMap { object[$0]?.stringValue }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    /// 从 `rawOutput` 提取进程退出码。
    /// - Parameter raw: 协议里的原始出参
    /// - Returns: 退出码;没有则 nil
    public static func exitCode(from raw: JSONValue?) -> Int? {
        guard case .object(let object)? = raw else { return nil }
        return (object["exitCode"] ?? object["exit_code"] ?? object["code"])?.intValue
    }

    /// 从 `title` 推导工具名:`Running view_file` → `view_file`(其余形态不推导)。
    /// - Parameter title: 工具标题
    /// - Returns: 工具名;无法推导返回 nil
    public static func toolName(fromTitle title: String) -> String? {
        for prefix in ["Running ", "Run "] where title.hasPrefix(prefix) {
            let rest = title.dropFirst(prefix.count).trimmingCharacters(in: CharacterSet(charactersIn: "? ").union(.whitespaces))
            // 只认「单个标识符」:带空格的是命令行或自然语言
            if !rest.isEmpty, rest.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) { return rest }
        }
        return nil
    }
}

public extension ToolCall {
    /// 工具结果文本(来自 `rawOutput`)。
    var resultText: String? { ToolInputNormalizer.resultText(from: rawOutput) }

    /// 进程退出码(来自 `rawOutput`)。
    var exitCode: Int? { ToolInputNormalizer.exitCode(from: rawOutput) }

    /// 失败原因:仅在失败状态下,取 `rawOutput` 里的错误文本;没有则 nil。
    var failureText: String? {
        guard status == .failed else { return nil }
        if let text = resultText { return text }
        if case .object(let object)? = rawOutput {
            return (object["error"] ?? object["message"])?.stringValue
        }
        return nil
    }
}
