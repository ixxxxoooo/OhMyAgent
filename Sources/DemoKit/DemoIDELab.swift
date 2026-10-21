// @author ixxxxoooo
// IDE 实验室素材(I0):给 IDE 模式的编辑器性能与语法高亮验证用的确定性文件,生成在 `perf-multitab/ide-lab/` 下。
// - `big/Big50k.swift`:50000 行 / 约 1.6MB 的 Swift 源码(不换行打开、输入延迟、滚动、内存预算的统一测量对象);
// - `big/Medium2k.swift`:2000 行普通文件(首个高亮帧、标签切换);
// - `big/LongLines.json`:含超长单行(不换行宽度估算、横向滚动);
// - `lang/*`:首批 tree-sitter 语言各一份样例(Swift、TS/JS/TSX、Python、Go、Rust、C/C++、JSON、YAML、TOML、Markdown、HTML、CSS、Bash)。
// 内容全部确定性生成(无随机),同一版本永远得到同样的文件。

import Foundation

/// IDE 实验室素材生成器。
enum DemoIDELab {
    /// 大文件行数。
    static let bigLineCount = 50_000
    /// 普通文件行数。
    static let mediumLineCount = 2_000

    /// 实验室相对 `perf-multitab` 的目录名。
    static let directoryName = "ide-lab"

    /// 生成全部素材。
    /// - Parameter root: `perf-multitab` 项目根目录
    static func build(in root: URL) throws {
        let lab = root.appendingPathComponent(directoryName, isDirectory: true)
        try write(lab, "README.md", readme)
        try write(lab, "big/Big50k.swift", swiftLines(count: bigLineCount))
        try write(lab, "big/Medium2k.swift", swiftLines(count: mediumLineCount))
        try write(lab, "big/LongLines.json", longLinesJSON)
        for (name, text) in languageSamples { try write(lab, "lang/\(name)", text) }
    }

    /// 确定性的 Swift 源码,恰好 `count` 行(每 12 行一个结构体块,行长混合,平均约 32 字节)。
    /// - Parameter count: 目标行数,必须为正
    /// - Returns: 源码文本(以换行结尾)
    static func swiftLines(count: Int) -> String {
        guard count > 0 else { return "" }
        var lines: [String] = []
        lines.reserveCapacity(count)
        var block = 0
        while lines.count < count {
            block += 1
            let n = block
            lines.append("// MARK: - Block \(n)")
            lines.append("/// 第 \(n) 个演示结构体:用于 IDE 编辑器的性能测量,内容确定性生成。")
            lines.append("struct Block\(n): Sendable, Hashable {")
            lines.append("    var value: Int = \(n % 997)")
            lines.append("    func compute(_ x: Int) -> Int {")
            lines.append("        let y = x &* \(n % 31 + 2) &+ value // 乘加后取模")
            lines.append("        return y % \(n % 89 + 11)")
            lines.append("    }")
            lines.append("    static let name = \"block-\(n)\"")
            lines.append("    static let note = \"Block \(n) computes a bounded checksum\"")
            lines.append("}")
            lines.append("")
        }
        return lines.prefix(count).joined(separator: "\n") + "\n"
    }

    /// 含若干超长单行的 JSON(一行约 30 万字符,用来测不换行模式的宽度估算与横向滚动)。
    static var longLinesJSON: String {
        let items = (0..<20_000).map { "{\"id\":\($0),\"name\":\"item-\($0)\",\"tags\":[\"a\",\"b\"]}" }
        let minified = "[" + items.joined(separator: ",") + "]"
        return "{\n  \"note\": \"下面一行是压缩过的超长 JSON\",\n  \"payload\": \(minified),\n  \"tail\": true\n}\n"
    }

    private static func write(_ dir: URL, _ relative: String, _ text: String) throws {
        let url = dir.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    static let readme = """
    # ide-lab

    IDE 模式的编辑器实验室素材(演示模式 `perf-multitab` 项目内,不进 Git):

    - `big/Big50k.swift`:50000 行 / 约 1.6MB,测打开、输入延迟、滚动与内存;
    - `big/Medium2k.swift`:2000 行普通文件;
    - `big/LongLines.json`:含超长单行;
    - `lang/`:各语言样例,用于语法高亮快照与回退验证。

    """
}
