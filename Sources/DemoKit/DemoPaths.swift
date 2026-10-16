// @author ygw
// 演示模式的沙盒目录布局:所有演示数据都放在一个独立目录里,绝不触碰真实的工作台状态与 ~/.claude。

import Foundation

/// 演示沙盒路径。
public struct DemoPaths: Sendable, Equatable {
    /// 沙盒根目录
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// 解析沙盒根目录:环境变量 `OMA_DEMO_ROOT` 优先,否则 `~/Library/Caches/OhMyAgent/Demo`。
    /// - Parameter environment: 环境变量(测试可注入)
    public static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) -> DemoPaths {
        if let custom = environment["OMA_DEMO_ROOT"], !custom.isEmpty {
            return DemoPaths(root: URL(fileURLWithPath: custom, isDirectory: true).standardizedFileURL)
        }
        let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/OhMyAgent/Demo", isDirectory: true)
        return DemoPaths(root: base)
    }

    /// 演示项目所在目录
    public var projects: URL { root.appendingPathComponent("projects", isDirectory: true) }
    /// 本地「远端」裸仓库所在目录
    public var remotes: URL { root.appendingPathComponent("remotes", isDirectory: true) }
    /// 演示用主目录(内含演示 `.claude`)
    public var home: URL { root.appendingPathComponent("home", isDirectory: true) }
    /// 应用状态目录(演示版 `workbench.json` 等)
    public var support: URL { root.appendingPathComponent("support", isDirectory: true) }
    /// 演示版工作台状态文件
    public var workbenchFile: URL { support.appendingPathComponent("workbench.json") }
    /// 数据版本标记文件:版本一致且未要求重置时跳过重建
    public var marker: URL { root.appendingPathComponent(".oma-demo-version") }

    /// 某个演示项目的目录。
    /// - Parameter name: 项目名
    public func project(_ name: String) -> URL { projects.appendingPathComponent(name, isDirectory: true) }
}
