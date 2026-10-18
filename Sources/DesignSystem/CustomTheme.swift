// @author ixxxxoooo
// 自定义主题:JSON 文件格式、校验、与 `ThemePackage` 的互转,以及磁盘存取。
// 目录:`~/Library/Application Support/OhMyAgent/themes/*.json`;可导入/导出分享。

import Foundation
import OMLog

/// 自定义主题文件(JSON)。所有颜色都是可选的 `#RRGGBB`,缺省沿用 `base` 指定的基线。
public struct CustomThemeFile: Codable, Equatable, Sendable {
    /// 文件格式版本
    public var version: Int = 1
    /// 主题标识(字母、数字、连字符;导入时会加 `custom-` 前缀)
    public var id: String
    /// 显示名
    public var name: String
    /// 基线:`light` 或 `dark`
    public var base: String
    /// 颜色覆盖:键见 `CustomThemeFile.colorKeys`
    public var colors: [String: String] = [:]
    /// 终端 ANSI 16 色(`#RRGGBB`),可选
    public var ansi: [String]?
    /// 风格倍率:cornerScale / strokeScale / shadowScale / glassTint / fillScale
    public var style: [String: Double]?

    public init(id: String, name: String, base: String, colors: [String: String] = [:], ansi: [String]? = nil, style: [String: Double]? = nil) {
        self.id = id
        self.name = name
        self.base = base
        self.colors = colors
        self.ansi = ansi
        self.style = style
    }

    /// 允许覆盖的颜色键(与 `ThemePalette` 字段一一对应)。
    public static let colorKeys: [String] = [
        "surface", "card", "sidebarBackground", "editorBackground", "editorForeground", "gutterBackground", "gutterForeground", "currentLine",
        "accent", "accent2", "success", "danger", "warning", "diffAdded", "diffRemoved",
        "keyword", "string", "comment", "number", "type", "function", "property",
    ]
}

/// 自定义主题的校验与转换错误。
public enum CustomThemeError: Error, Equatable, LocalizedError {
    case invalidJSON
    case emptyName
    case invalidBase
    case invalidColor(key: String)
    case invalidANSI
    case unsupportedVersion(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidJSON: return String(localized: "不是有效的主题文件(JSON 解析失败)。")
        case .emptyName: return String(localized: "主题名称不能为空。")
        case .invalidBase: return String(localized: "基线必须是 light 或 dark。")
        case .invalidColor(let key): return String(localized: "颜色「\(key)」不是有效的 #RRGGBB。")
        case .invalidANSI: return String(localized: "ANSI 颜色必须正好 16 个有效的 #RRGGBB。")
        case .unsupportedVersion(let version): return String(localized: "不支持的主题文件版本:\(version)。")
        }
    }
}

extension CustomThemeFile {
    /// 把任意字符串规整为合法 id 片段(小写字母、数字、连字符)。
    /// - Parameter raw: 原始字符串
    public static func sanitizedID(_ raw: String) -> String {
        let lowered = raw.lowercased().map { $0.isLetter && $0.isASCII || $0.isNumber && $0.isASCII ? $0 : "-" }
        var text = String(lowered)
        while text.contains("--") { text = text.replacingOccurrences(of: "--", with: "-") }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return text.isEmpty ? "theme" : text
    }

    /// 解析 JSON 数据。
    /// - Parameter data: 文件内容
    public static func decode(_ data: Data) throws -> CustomThemeFile {
        do { return try JSONDecoder().decode(CustomThemeFile.self, from: data) } catch { throw CustomThemeError.invalidJSON }
    }

    /// 编码为易读的 JSON(键排序,便于版本管理与分享)。
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    /// 校验并生成主题包。
    /// - Returns: 分组为 `.custom`、id 带 `custom-` 前缀的主题包
    public func makePackage() throws -> ThemePackage {
        guard version == 1 else { throw CustomThemeError.unsupportedVersion(version) }
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw CustomThemeError.emptyName }
        let isDark: Bool
        switch base.lowercased() {
        case "dark": isDark = true
        case "light": isDark = false
        default: throw CustomThemeError.invalidBase
        }
        var palette = isDark ? ThemePalette.darkBase : ThemePalette.lightBase
        for (key, hex) in colors {
            guard Self.colorKeys.contains(key) else { continue }
            guard let rgb = ThemeRGB(hexString: hex) else { throw CustomThemeError.invalidColor(key: key) }
            palette.setColor(key, rgb)
        }
        // 只给了 surface 没给编辑器背景时,编辑器背景跟随 surface
        if colors["editorBackground"] == nil, let surface = colors["surface"].flatMap(ThemeRGB.init(hexString:)) { palette.editorBackground = surface }
        if colors["sidebarBackground"] == nil { palette.sidebarBackground = palette.surface.mixed(with: palette.editorForeground, isDark ? 0.06 : 0.04) }
        if let ansi {
            let parsed = ansi.compactMap(ThemeRGB.init(hexString:))
            guard ansi.count == 16, parsed.count == 16 else { throw CustomThemeError.invalidANSI }
            palette.ansi = parsed
        }
        if let style {
            palette.style = ThemeStyle(
                cornerScale: Self.clamp(style["cornerScale"] ?? 1, 0.3, 1.6),
                strokeScale: Self.clamp(style["strokeScale"] ?? 1, 0.3, 2),
                shadowScale: Self.clamp(style["shadowScale"] ?? 1, 0, 2),
                glassTint: Self.clamp(style["glassTint"] ?? 0, 0, 0.3),
                fillScale: Self.clamp(style["fillScale"] ?? 1, 0.5, 2)
            )
        }
        let finalID = "custom-" + Self.sanitizedID(id.hasPrefix("custom-") ? String(id.dropFirst(7)) : id)
        return ThemePackage(id: finalID, name: title, group: .custom, tone: isDark ? .dark : .light, palette: palette)
    }

    /// 由主题包导出文件(用于「导出」与「以当前主题为基础新建」)。
    /// - Parameters:
    ///   - package: 主题包(系统主题没有调色板,返回 nil)
    ///   - id: 新 id(缺省沿用)
    ///   - name: 新名称(缺省沿用)
    public static func export(_ package: ThemePackage, id: String? = nil, name: String? = nil) -> CustomThemeFile? {
        guard let palette = package.palette else { return nil }
        var colors: [String: String] = [:]
        for key in colorKeys { if let rgb = palette.color(key) { colors[key] = rgb.hexString } }
        let style: [String: Double] = [
            "cornerScale": palette.style.cornerScale, "strokeScale": palette.style.strokeScale, "shadowScale": palette.style.shadowScale,
            "glassTint": palette.style.glassTint, "fillScale": palette.style.fillScale,
        ]
        return CustomThemeFile(
            id: id ?? package.id, name: name ?? package.name, base: palette.isDark ? "dark" : "light",
            colors: colors, ansi: palette.ansiColors.map(\.hexString), style: style
        )
    }

    private static func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double { min(max(value, low), high) }
}

extension ThemePalette {
    /// 按键写入颜色。
    mutating func setColor(_ key: String, _ rgb: ThemeRGB) {
        switch key {
        case "surface": surface = rgb
        case "card": card = rgb
        case "sidebarBackground": sidebarBackground = rgb
        case "editorBackground": editorBackground = rgb
        case "editorForeground": editorForeground = rgb
        case "gutterBackground": gutterBackground = rgb
        case "gutterForeground": gutterForeground = rgb
        case "currentLine": currentLine = rgb
        case "accent": accent = rgb
        case "accent2": accent2 = rgb
        case "success": success = rgb
        case "danger": danger = rgb
        case "warning": warning = rgb
        case "diffAdded": diffAdded = rgb
        case "diffRemoved": diffRemoved = rgb
        case "keyword": keyword = rgb
        case "string": string = rgb
        case "comment": comment = rgb
        case "number": number = rgb
        case "type": type = rgb
        case "function": function = rgb
        case "property": property = rgb
        default: break
        }
    }

    /// 按键读取颜色(侧栏缺省时按推导值返回)。
    func color(_ key: String) -> ThemeRGB? {
        switch key {
        case "surface": surface
        case "card": card
        case "sidebarBackground": sidebarBackground ?? surface.mixed(with: editorForeground, isDark ? 0.06 : 0.04)
        case "editorBackground": editorBackground
        case "editorForeground": editorForeground
        case "gutterBackground": gutterBackground
        case "gutterForeground": gutterForeground
        case "currentLine": currentLine
        case "accent": accent
        case "accent2": accent2
        case "success": success
        case "danger": danger
        case "warning": warning
        case "diffAdded": diffAdded
        case "diffRemoved": diffRemoved
        case "keyword": keyword
        case "string": string
        case "comment": comment
        case "number": number
        case "type": type
        case "function": function
        case "property": property
        default: nil
        }
    }
}

/// 自定义主题的磁盘存取。
public enum CustomThemeStore {
    /// 主题目录(`Application Support/OhMyAgent/themes`)。
    public static var directory: URL {
        AppEnv.supportDirectory.appendingPathComponent("themes", isDirectory: true)
    }

    /// 读取目录下全部有效主题;无效文件记录日志后跳过。
    /// - Parameter directory: 目录(测试可注入)
    public static func loadAll(from directory: URL = directory) -> [ThemePackage] {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        var result: [ThemePackage] = []
        for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where url.pathExtension.lowercased() == "json" {
            do {
                let data = try Data(contentsOf: url)
                let package = try CustomThemeFile.decode(data).makePackage()
                if !result.contains(where: { $0.id == package.id }) { result.append(package) }
            } catch {
                Log.ui.warning("自定义主题无效,已跳过", ["file": url.lastPathComponent, "error": "\(error)"])
            }
        }
        return result
    }

    /// 保存主题文件(文件名取 id)。
    /// - Parameters:
    ///   - file: 主题文件
    ///   - directory: 目录(测试可注入)
    /// - Returns: 保存后生效的主题包
    @discardableResult
    public static func save(_ file: CustomThemeFile, to directory: URL = directory) throws -> ThemePackage {
        let package = try file.makePackage()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var normalized = file
        normalized.id = package.id
        try normalized.encoded().write(to: directory.appendingPathComponent("\(package.id).json"), options: .atomic)
        return package
    }

    /// 删除自定义主题。
    /// - Parameters:
    ///   - id: 主题 id
    ///   - directory: 目录(测试可注入)
    public static func delete(id: String, from directory: URL = directory) {
        let url = directory.appendingPathComponent("\(CustomThemeFile.sanitizedID(id)).json")
        do { try FileManager.default.removeItem(at: url) } catch { Log.ui.warning("删除自定义主题失败", ["id": id, "error": "\(error)"]) }
    }
}
