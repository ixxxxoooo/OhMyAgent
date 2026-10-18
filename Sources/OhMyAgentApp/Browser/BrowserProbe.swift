// @author ixxxxoooo
// 调试探针(脚本化界面验证,仅在设置了环境变量时生效):在内置浏览器标签里按顺序执行 Agent 同款的浏览器命令,并把结果写到文件。
// `OMA_BROWSER_PROBE=<输出文件>` 启用;`OMA_BROWSER_ACTIONS` 用分号分隔动作:
//   snapshot | click:<ref> | type:<ref>:<文本>[:submit] | scroll:<up|down|top|bottom|ref> | screenshot | console | network | tabs
// 截图保存为 `<输出文件>.png`。

import AppKit
import ChatKit
import Foundation

@MainActor
enum BrowserProbe {
    /// 执行探针。
    /// - Parameters:
    ///   - output: 输出文件路径
    ///   - actions: 动作脚本
    ///   - workspace: 工作区 ID
    static func run(output: String, actions: String, workspace: String) async {
        var log = ""
        func parse(_ item: String) -> BrowserCommand? {
            let parts = item.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            switch parts[0] {
            case "snapshot": return .snapshot
            case "click": return parts.count > 1 ? .click(ref: parts[1]) : nil
            case "type": return parts.count > 2 ? .type(ref: parts[1], text: parts[2], submit: parts.count > 3 && parts[3] == "submit") : nil
            case "scroll":
                guard parts.count > 1 else { return nil }
                switch parts[1] {
                case "up": return .scroll(.up)
                case "down": return .scroll(.down)
                case "top": return .scroll(.top)
                case "bottom": return .scroll(.bottom)
                default: return .scroll(.element(ref: parts[1]))
                }
            case "screenshot": return .screenshot
            case "console": return .console
            case "network": return .network
            case "tabs": return .tabs
            default: return nil
            }
        }
        for item in actions.split(separator: ";").map(String.init) {
            guard let command = parse(item) else { log += "### \(item)\n(无法解析)\n\n"; continue }
            try? await Task.sleep(for: .milliseconds(900))
            let result = await BrowserController.shared.run(command, workspace: workspace, activate: true)
            log += "### \(item)  [\(result.isError ? "失败" : "成功")]\n\(result.text)\n\n"
            if let png = result.imagePNG { try? png.write(to: URL(fileURLWithPath: output + ".png")) }
        }
        try? log.write(toFile: output, atomically: true, encoding: .utf8)
    }
}
