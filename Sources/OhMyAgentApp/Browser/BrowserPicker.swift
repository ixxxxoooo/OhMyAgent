// @author ixxxxoooo
// 内置浏览器的「选择元素」(对齐 Cursor):用户在页面里点选元素,元素信息与截图进入当前会话的输入框,
// 然后可以直接说「把这个按钮改成蓝色」。页面端脚本见 `BrowserScripts.pickStart`。

import AppKit
import ChatKit
import Foundation
import OMLog
import WebKit

extension BrowserTabModel {
    /// 开始或结束选择模式。
    /// - Parameter on: 是否开启
    func setPicking(_ on: Bool) async {
        guard !urlString.isEmpty else { return }
        do {
            _ = try await evaluate(on ? BrowserScripts.pickStart : BrowserScripts.pickStop)
            isPicking = on
        } catch {
            Log.app.warning("选择元素脚本失败", ["error": error.localizedDescription])
            isPicking = false
        }
    }

    /// 页面回传了选中的元素:整理信息、截取元素图,交给回调。
    /// - Parameter body: 页面消息(`info` 字段)
    func handlePick(_ body: [String: Any]) {
        isPicking = false
        guard let info = body["info"] as? [String: Any] else { return }
        func int(_ key: String) -> Int { (info[key] as? NSNumber)?.intValue ?? 0 }
        let element = PickedElement(
            url: info["url"] as? String ?? urlString, title: info["title"] as? String ?? title, tag: info["tag"] as? String ?? "div",
            selector: info["selector"] as? String ?? "", text: info["text"] as? String ?? "", html: info["html"] as? String ?? "",
            styles: (info["styles"] as? [String: String]) ?? [:], width: int("w"), height: int("h"), x: int("x"), y: int("y"))
        Task { @MainActor [weak self] in
            guard let self else { return }
            let png = await self.snapshot(rect: CGRect(x: element.x, y: element.y, width: element.width, height: element.height))
            self.onElementPicked?(element, png)
        }
    }

    /// 截取视口里的一块区域(元素图);尺寸不合理返回 nil。
    /// - Parameter rect: 视口坐标里的区域
    private func snapshot(rect: CGRect) async -> Data? {
        let bounds = webView.bounds
        let clipped = rect.intersection(bounds)
        guard clipped.width >= 4, clipped.height >= 4 else { return nil }
        let configuration = WKSnapshotConfiguration()
        configuration.rect = clipped
        configuration.snapshotWidth = NSNumber(value: min(Double(clipped.width), 900))
        guard let image = try? await webView.takeSnapshot(configuration: configuration),
              let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    /// 显示一条选择结果提示,3 秒后清除。
    /// - Parameter text: 提示文字
    func showPickNote(_ text: String) {
        pickNote = text
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            if self?.pickNote == text { self?.pickNote = nil }
        }
    }
}

extension BrowserController {
    /// 选中元素后:把元素信息写进该工作区当前会话的输入框,并附上元素截图。
    /// - Parameters:
    ///   - element: 元素
    ///   - png: 元素截图
    ///   - workspace: 工作区
    ///   - tab: 来源标签(用来显示提示)
    func deliver(_ element: PickedElement, png: Data?, workspace: String, to tab: BrowserTabModel) {
        guard let session = AppEnvironment.shared.workbench.sessions[workspace] else {
            tab.showPickNote(String(localized: "没有可用的会话,元素未加入输入框"))
            return
        }
        let text = element.promptText()
        let draft = session.draft
        session.draft = draft.isEmpty ? text + "\n\n" : draft + (draft.hasSuffix("\n") ? "" : "\n") + text + "\n\n"
        if let png, session.canAttachImages {
            session.addAttachment(ImageAttachment(data: png, mimeType: "image/png", name: String(localized: "元素截图 \(element.summary)")))
        }
        tab.showPickNote(String(localized: "已把 \(element.summary) 加入输入框"))
        Log.app.info("已选择页面元素", ["tag": element.tag, "selector": String(element.selector.prefix(80))])
    }
}
