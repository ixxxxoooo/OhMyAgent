// @author ixxxxoooo
// IDE 切换文件闪烁复现钩子:
// `OMA_IDE_SWITCH=路径1|路径2|…`(相对路径取工作区根)启动后在这些文件间循环切换;
// `OMA_IDE_SWITCH_MS`(默认 1200)切换间隔,`OMA_IDE_SWITCH_ROUNDS`(默认 6)轮数,
// `OMA_IDE_SWITCH_PREVIEW=1` 用预览标签(单击文件)的方式原地替换,否则每个文件各占一个标签。

import AppKit
import Foundation
import IDEKit

@MainActor
enum IDESwitchProbe {
    /// 在 IDE 工作区里循环切换文件。
    /// - Parameters:
    ///   - workspace: IDE 工作区
    ///   - env: 环境变量
    static func run(_ workspace: IDEWorkspace, env: [String: String]) async {
        guard let raw = env["OMA_IDE_SWITCH"], !raw.isEmpty, let base = workspace.root else { return }
        let paths = raw.split(separator: "|").map { String($0) }.map { $0.hasPrefix("/") ? $0 : base + "/" + $0 }
        guard paths.count > 1 else { return }
        let interval = Int(env["OMA_IDE_SWITCH_MS"] ?? "") ?? 1200
        let rounds = Int(env["OMA_IDE_SWITCH_ROUNDS"] ?? "") ?? 6
        let preview = env["OMA_IDE_SWITCH_PREVIEW"] == "1"
        let window = NSApp.windows.filter { $0.isVisible && $0.contentView != nil }.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
        let sampler = window?.contentView.map { IDEFrameSampler(view: $0) }
        // 先各打开一遍(冷打开,同样采样),再进入热切换
        for path in paths {
            sampler?.mark("冷 " + (path as NSString).lastPathComponent)
            workspace.model.openFile(path, line: nil, preview: preview)
            try? await Task.sleep(for: .milliseconds(1500))
        }
        try? await Task.sleep(for: .seconds(1))
        for _ in 0..<rounds {
            for path in paths {
                sampler?.mark("热 " + (path as NSString).lastPathComponent)
                workspace.model.openFile(path, line: nil, preview: preview)
                try? await Task.sleep(for: .milliseconds(interval))
            }
        }
        if let sampler {
            let dir = env["OMA_IDE_SWITCH_OUT"] ?? NSTemporaryDirectory() + "ide-switch"
            let report = sampler.finish(into: dir)
            try? report.write(toFile: dir + "/report.txt", atomically: true, encoding: .utf8)
        }
    }
}
