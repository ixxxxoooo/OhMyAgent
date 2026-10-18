// @author ixxxxoooo
// 调试探针(脚本化界面验证,仅在设置了环境变量时生效):在内置浏览器标签里按顺序执行 Agent 同款的浏览器命令,并把结果写到文件。
// `OMA_BROWSER_PROBE=<输出文件>` 启用;`OMA_BROWSER_ACTIONS` 用分号分隔动作:
//   snapshot | click:<ref> | dblclick:<ref> | rightclick:<ref> | hover:<ref> | back | forward | reload | type:<ref>:<文本>[:submit] | scroll:<up|down|top|bottom|ref> | screenshot | console | network[:序号] | tabs
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
            case "dblclick": return parts.count > 1 ? .click(ref: parts[1], button: .left, double: true) : nil
            case "rightclick": return parts.count > 1 ? .click(ref: parts[1], button: .right, double: false) : nil
            case "hover": return parts.count > 1 ? .hover(ref: parts[1]) : nil
            case "back": return .history(.back)
            case "forward": return .history(.forward)
            case "reload": return .history(.reload)
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
            case "network": return .network(request: parts.count > 1 ? Int(parts[1]) : nil)
            case "tabs": return .tabs
            default: return nil
            }
        }
        for item in actions.split(separator: ";").map(String.init) {
            // pick:<ref>:用合成鼠标事件在页面里「选择元素」并检查结果(输入框草稿与图片附件)
            if item == "pickon" {
                try? await Task.sleep(for: .milliseconds(900))
                let model = BrowserController.shared.tab(id: BrowserController.shared.activeID(workspace: workspace) ?? "", workspace: workspace)
                await model.setPicking(true)
                log += "### pickon  选择模式:\(model.isPicking)\n\n"
                continue
            }
            if item.hasPrefix("pick:") {
                let ref = String(item.dropFirst(5))
                try? await Task.sleep(for: .milliseconds(900))
                let model = BrowserController.shared.tab(id: BrowserController.shared.activeID(workspace: workspace) ?? "", workspace: workspace)
                await model.setPicking(true)
                _ = try? await model.evaluate("""
                const el = document.querySelector('[data-oma-ref="' + ref + '"]'); const r = el.getBoundingClientRect();
                const o = {bubbles: true, cancelable: true, view: window, clientX: r.left + r.width / 2, clientY: r.top + r.height / 2};
                document.dispatchEvent(new MouseEvent('mousemove', o)); document.dispatchEvent(new MouseEvent('click', o));
                return 'ok';
                """, arguments: ["ref": ref])
                try? await Task.sleep(for: .milliseconds(1500))
                let session = AppEnvironment.shared.workbench.sessions[workspace]
                log += "### \(item)  [已选择]\n提示条:\(model.pickNote ?? "(无)")  选择模式:\(model.isPicking)\n附件:\(session?.attachments.map { "\($0.name) \($0.data.count) 字节" } ?? [])\n草稿:\n\(session?.draft ?? "(无会话)")\n\n"
                continue
            }
            guard let command = parse(item) else { log += "### \(item)\n(无法解析)\n\n"; continue }
            try? await Task.sleep(for: .milliseconds(900))
            let result = await BrowserController.shared.run(command, workspace: workspace, activate: true)
            log += "### \(item)  [\(result.isError ? "失败" : "成功")]\n\(result.text)\n\n"
            if let png = result.imagePNG { try? png.write(to: URL(fileURLWithPath: output + ".png")) }
        }
        try? log.write(toFile: output, atomically: true, encoding: .utf8)
    }
}
