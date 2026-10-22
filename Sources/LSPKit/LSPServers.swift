// @author ixxxxoooo
// 语言服务器种类、可执行文件定位与工作区根目录推断。

import ACPKit
import Foundation

/// 支持的语言服务器。
public enum LSPServerKind: String, Sendable, CaseIterable, Hashable {
    case swift, typescript, python, go

    /// 展示名称。
    public var displayName: String {
        switch self {
        case .swift: return "sourcekit-lsp"
        case .typescript: return "typescript-language-server"
        case .python: return "pyright"
        case .go: return "gopls"
        }
    }

    /// 未安装时给用户的安装提示。
    public var installHint: String {
        switch self {
        case .swift: return String(localized: "需要安装 Xcode 或 Swift 工具链(自带 sourcekit-lsp)")
        case .typescript: return "npm i -g typescript-language-server typescript"
        case .python: return String(localized: "npm i -g pyright(或 pip install basedpyright)")
        case .go: return "go install golang.org/x/tools/gopls@latest"
        }
    }

    /// 候选可执行文件名(按优先级)。
    var executableNames: [String] {
        switch self {
        case .swift: return ["sourcekit-lsp"]
        case .typescript: return ["typescript-language-server"]
        case .python: return ["pyright-langserver", "basedpyright-langserver"]
        case .go: return ["gopls"]
        }
    }

    var arguments: [String] {
        switch self {
        case .swift, .go: return []
        case .typescript, .python: return ["--stdio"]
        }
    }

    /// 标识工作区根的文件名。
    var rootMarkers: [String] {
        switch self {
        case .swift: return ["Package.swift"]
        case .typescript: return ["tsconfig.json", "jsconfig.json", "package.json"]
        case .python: return ["pyrightconfig.json", "pyproject.toml", "setup.py", "setup.cfg", "requirements.txt"]
        case .go: return ["go.work", "go.mod"]
        }
    }

    /// 根据路径推断应使用的服务器。
    /// - Parameter path: 文件路径
    /// - Returns: 服务器种类;不支持的类型返回 nil
    public static func kind(forPath path: String) -> LSPServerKind? {
        guard let languageID = languageID(forPath: path) else { return nil }
        switch languageID {
        case "swift": return .swift
        case "typescript", "typescriptreact", "javascript", "javascriptreact": return .typescript
        case "python": return .python
        case "go": return .go
        default: return nil
        }
    }

    /// LSP `languageId`。
    /// - Parameter path: 文件路径
    public static func languageID(forPath path: String) -> String? {
        switch (path as NSString).pathExtension.lowercased() {
        case "swift": return "swift"
        case "ts", "mts", "cts": return "typescript"
        case "tsx": return "typescriptreact"
        case "js", "mjs", "cjs": return "javascript"
        case "jsx": return "javascriptreact"
        case "py", "pyi": return "python"
        case "go": return "go"
        default: return nil
        }
    }
}

/// 在 GUI 应用的精简 PATH 之外,补充常见安装位置来定位服务器。
public enum LSPServerLocator {
    /// 可搜索的目录(按优先级):项目本地 `node_modules/.bin`、PATH、常见安装目录、nvm 各版本。
    /// - Parameters:
    ///   - projectRoot: 项目根目录
    ///   - environment: 环境变量(可注入以便测试)
    ///   - home: 用户主目录
    public static func searchDirectories(projectRoot: String, environment: [String: String], home: String) -> [String] {
        var dirs = [projectRoot + "/node_modules/.bin"]
        dirs += (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        dirs += [
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin",
            home + "/.local/bin", home + "/.npm-global/bin", home + "/.bun/bin", home + "/.volta/bin",
            home + "/go/bin", "/usr/local/go/bin",
            "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin",
            "/Library/Developer/CommandLineTools/usr/bin",
        ]
        let nvm = home + "/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvm) {
            dirs += versions.sorted(by: >).map { nvm + "/" + $0 + "/bin" }
        }
        var seen = Set<String>()
        return dirs.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// 定位服务器并生成启动配置。
    /// - Parameters:
    ///   - kind: 服务器种类
    ///   - projectRoot: 项目根目录
    ///   - workspaceRoot: 工作区根目录(进程工作目录)
    ///   - environment: 环境变量
    ///   - home: 用户主目录
    ///   - isExecutable: 可执行判断(可注入)
    /// - Returns: 启动配置;找不到返回 nil
    public static func locate(
        _ kind: LSPServerKind,
        projectRoot: String,
        workspaceRoot: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory(),
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> ProcessLaunch? {
        let dirs = searchDirectories(projectRoot: projectRoot, environment: environment, home: home)
        for name in kind.executableNames {
            for dir in dirs {
                let candidate = dir + "/" + name
                guard isExecutable(candidate) else { continue }
                // node 脚本的 shebang 依赖 PATH 中有 node,GUI 启动时 PATH 很短,这里补全
                let path = (dirs + [environment["PATH"] ?? ""]).joined(separator: ":")
                return ProcessLaunch(executable: candidate, arguments: kind.arguments, environment: ["PATH": path], workingDirectory: workspaceRoot)
            }
        }
        return nil
    }

    /// 从文件所在目录向上查找工作区根标记,不越过项目根。
    /// - Parameters:
    ///   - path: 文件路径
    ///   - kind: 服务器种类
    ///   - projectRoot: 项目根目录
    ///   - fileExists: 存在性判断(可注入)
    /// - Returns: 工作区根;找不到标记时回退项目根(文件不在项目内则取其所在目录)
    public static func workspaceRoot(
        for path: String,
        kind: LSPServerKind,
        projectRoot: String,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> String {
        let root = (projectRoot as NSString).standardizingPath
        var dir = ((path as NSString).deletingLastPathComponent as NSString).standardizingPath
        guard dir == root || dir.hasPrefix(root + "/") else { return dir }
        while true {
            if kind.rootMarkers.contains(where: { fileExists(dir + "/" + $0) }) { return dir }
            if dir == root || dir == "/" || dir.isEmpty { return root }
            dir = (dir as NSString).deletingLastPathComponent
        }
    }
}
