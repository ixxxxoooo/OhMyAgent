// @author ixxxxoooo
// Plan 正文里的文件路径链接化:把行内代码里指向项目内真实文件的路径(可带 `:行号`)改写成 `oma-file:` 链接,
// 点击后按「文件默认打开位置」打开。纯函数,文件是否存在由调用方注入,便于测试。

import Foundation

/// Plan 路径链接器。
public enum PlanPathLinker {
    /// 链接的 scheme。
    public static let scheme = "oma-file"

    /// 把正文里的行内代码路径改写成链接。围栏代码块内部保持原样。
    /// - Parameters:
    ///   - markdown: Markdown 正文
    ///   - root: 项目根目录(相对路径据此解析)
    ///   - exists: 判断绝对路径是否为已存在的普通文件
    /// - Returns: 改写后的正文
    public static func link(_ markdown: String, root: String, exists: (String) -> Bool) -> String {
        guard !markdown.isEmpty, !root.isEmpty else { return markdown }
        var inFence = false
        var lines: [String] = []
        for line in markdown.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { inFence.toggle(); lines.append(line); continue }
            lines.append(inFence ? line : linkLine(line, root: root, exists: exists))
        }
        return lines.joined(separator: "\n")
    }

    /// 解析 `oma-file:` 链接。
    /// - Parameter url: 链接
    /// - Returns: (绝对路径, 行号);不是该 scheme 为 nil
    public static func parse(link url: URL) -> (String, Int?)? {
        guard url.scheme == scheme, let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let path = items.first(where: { $0.name == "path" })?.value, !path.isEmpty else { return nil }
        return (path, items.first(where: { $0.name == "line" })?.value.flatMap(Int.init))
    }

    /// 单行内改写所有 `` `路径` `` 片段。
    private static func linkLine(_ line: String, root: String, exists: (String) -> Bool) -> String {
        guard line.contains("`") else { return line }
        var output = ""
        var rest = Substring(line)
        while let open = rest.firstIndex(of: "`") {
            output += rest[..<open]
            let afterOpen = rest.index(after: open)
            guard let close = rest[afterOpen...].firstIndex(of: "`") else { output += rest[open...]; return output }
            let code = String(rest[afterOpen..<close])
            if let target = resolve(code, root: root, exists: exists), let url = makeLink(path: target.path, line: target.line) {
                output += "[\(code)](\(url))"
            } else {
                output += rest[open...close]
            }
            rest = rest[rest.index(after: close)...]
        }
        output += rest
        return output
    }

    /// 解析行内代码:去掉 `:行号` 后缀,相对路径按项目根展开,存在才算。
    private static func resolve(_ code: String, root: String, exists: (String) -> Bool) -> (path: String, line: Int?)? {
        guard !code.isEmpty, code.count < 300, !code.contains(" "), code.contains("/") || code.contains(".") else { return nil }
        var pathPart = code
        var line: Int?
        if let colon = code.lastIndex(of: ":"), let number = Int(code[code.index(after: colon)...]), number > 0 {
            pathPart = String(code[..<colon])
            line = number
        }
        guard !pathPart.isEmpty, !pathPart.hasPrefix("http"), pathPart.rangeOfCharacter(from: CharacterSet(charactersIn: "()[]")) == nil else { return nil }
        let absolute = pathPart.hasPrefix("/") ? pathPart : (root as NSString).appendingPathComponent(pathPart)
        let standard = (absolute as NSString).standardizingPath
        return exists(standard) ? (standard, line) : nil
    }

    private static func makeLink(path: String, line: Int?) -> String? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "open"
        components.queryItems = [URLQueryItem(name: "path", value: path)] + (line.map { [URLQueryItem(name: "line", value: String($0))] } ?? [])
        return components.string
    }
}
