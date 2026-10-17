// @author ixxxxoooo
// Canvas 与会话的衔接:Bridge 的 canvas_create / canvas_update / canvas_list 落到 `CanvasStore`,
// 并通知应用层打开/刷新画布标签;同时提供从工具调用还原「画布卡片」信息的辅助。

import ACPKit
import AgentHost
import CanvasKit
import Foundation
import Observation
import OMLog

/// 请求应用层打开(并聚焦)某个画布。
public struct CanvasOpenRequest: Identifiable, Sendable, Equatable {
    public var id: String { canvasID }
    public var canvasID: String
    public var title: String

    public init(canvasID: String, title: String) {
        self.canvasID = canvasID
        self.title = title
    }
}

/// 画布修订广播:Agent 更新画布后递增对应修订号,已打开的标签据此重新读盘。
@MainActor
@Observable
public final class CanvasHub {
    public static let shared = CanvasHub()
    public private(set) var revisions: [String: Int] = [:]

    private init() {}

    /// 记录一次变更。
    /// - Parameter id: 画布标识
    public func bump(_ id: String) { revisions[id, default: 0] += 1 }

    /// 当前修订号(未变更过为 0)。
    /// - Parameter id: 画布标识
    public func revision(of id: String) -> Int { revisions[id] ?? 0 }
}

/// 画布列表缓存(中央搜索等界面读取;磁盘读取放在后台线程)。
@MainActor
@Observable
public final class CanvasListCache {
    public static let shared = CanvasListCache()
    public private(set) var items: [CanvasSummary] = []

    private init() {}

    /// 重新读取全部画布摘要。
    public func refresh() async {
        let list = await Task.detached(priority: .utility) { CanvasStore.app.list() }.value
        items = list
    }
}

/// 工具调用里的画布引用(用于在工具行下渲染「画布卡片」)。
public struct CanvasToolRef: Sendable, Equatable {
    public var canvasID: String
    public var title: String?
    public var isUpdate: Bool

    /// 从工具调用还原画布引用;不是画布工具或尚未完成时返回 nil。
    /// - Parameter tool: 工具调用
    public static func of(_ tool: ToolCall) -> CanvasToolRef? {
        guard let name = tool.name, name.hasPrefix("mcp__"),
              name.hasSuffix("__canvas_create") || name.hasSuffix("__canvas_update"),
              tool.status == .completed else { return nil }
        var texts: [String] = []
        for item in tool.content {
            if case .content(.text(let text)) = item { texts.append(text) }
        }
        if let output = tool.rawOutput?.stringValue { texts.append(output) }
        guard let id = texts.lazy.compactMap({ Self.extractID(from: $0) }).first else { return nil }
        return CanvasToolRef(canvasID: id, title: tool.rawInput?["title"]?.stringValue, isUpdate: name.hasSuffix("__canvas_update"))
    }

    /// 在结果文本里找 `canvas_id: <id>`。
    /// - Parameter text: 工具结果文本
    static func extractID(from text: String) -> String? {
        guard let range = text.range(of: "canvas_id:") else { return nil }
        let rest = text[range.upperBound...].drop { $0 == " " }
        let id = String(rest.prefix { $0.isLetter || $0.isNumber || $0 == "-" })
        return CanvasStore.isValid(id: id) ? id : nil
    }
}

extension SessionBridge {
    /// 画布类扩展工具的实现(在后台线程读写磁盘,仅 UI 通知回到主线程)。
    /// - Parameters:
    ///   - tool: 画布工具
    ///   - arguments: MCP 入参
    func callCanvas(_ tool: BridgeTool, arguments: JSONValue) async -> BridgeResult {
        guard let context = await MainActor.run(body: { model.map { ($0.canvasStore, $0.workspace.path) } }) else {
            return BridgeResult("会话已关闭", isError: true)
        }
        let (store, workspace) = context
        do {
            switch tool {
            case .canvasCreate:
                guard let title = arguments["title"]?.stringValue else { return BridgeResult("缺少 title 参数", isError: true) }
                guard let blocksJSON = arguments["blocks"] else { return BridgeResult("缺少 blocks 参数(块数组)", isError: true) }
                let blocks = try CanvasParser.parseBlocks(try JSONEncoder().encode(blocksJSON))
                let document = try store.create(title: title, blocks: blocks, projectPath: workspace)
                await publish(document, focus: true)
                return BridgeResult(Self.summary(of: document, verb: "created"))
            case .canvasUpdate:
                guard let id = arguments["id"]?.stringValue else { return BridgeResult("缺少 id 参数", isError: true) }
                let blocks = try arguments["blocks"].map { try CanvasParser.parseBlocks(try JSONEncoder().encode($0)) }
                let appended = try arguments["append_blocks"].map { try CanvasParser.parseBlocks(try JSONEncoder().encode($0)) }
                guard arguments["title"] != nil || blocks != nil || appended != nil else {
                    return BridgeResult("至少提供 title、blocks、append_blocks 之一", isError: true)
                }
                let document = try store.update(id: id, title: arguments["title"]?.stringValue, blocks: blocks, appendBlocks: appended)
                await publish(document, focus: false)
                return BridgeResult(Self.summary(of: document, verb: "updated"))
            case .canvasList:
                let list = store.list(projectPath: workspace)
                if list.isEmpty { return BridgeResult("No canvases yet for this project.") }
                let lines = list.map { "- canvas_id: \($0.id) | \($0.title) | \($0.blockCount) blocks" }
                return BridgeResult(lines.joined(separator: "\n"))
            default:
                return BridgeResult("不是画布工具", isError: true)
            }
        } catch let error as CanvasError {
            return BridgeResult("Canvas error: \(error.message)", isError: true)
        } catch {
            Log.bridge.error("Canvas 工具失败", error: error)
            return BridgeResult("Canvas error: \(error.localizedDescription)", isError: true)
        }
    }

    private static func summary(of document: CanvasDocument, verb: String) -> String {
        "Canvas \(verb). canvas_id: \(document.id)\ntitle: \(document.title)\nblocks: \(document.blockCount), revision: \(document.revision)\n"
            + "The user can see it in the OhMyAgent Canvas tab. To change it, call canvas_update with this canvas_id."
    }

    /// 通知应用层:刷新已打开的标签,新建时请求打开。
    private func publish(_ document: CanvasDocument, focus: Bool) async {
        await MainActor.run {
            CanvasHub.shared.bump(document.id)
            if focus { model?.canvasRequest = CanvasOpenRequest(canvasID: document.id, title: document.title) }
        }
    }
}

public extension CanvasStore {
    /// 应用默认存储(Application Support;演示模式经 `CFFIXED_USER_HOME` 自动落到沙盒)。
    static var app: CanvasStore { CanvasStore(directory: CanvasStore.defaultDirectory()) }
}
