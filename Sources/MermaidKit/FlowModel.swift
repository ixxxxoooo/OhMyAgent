// @author ixxxxoooo
// 流程类图的共享中间模型:flowchart / stateDiagram / classDiagram 均解析为它,再统一布局。

import CoreGraphics
import Foundation

/// 流程图节点。
struct FlowNode: Equatable {
    var id: String
    var text: String
    var shape: MShape = .rect
    /// 类图成员/方法
    var fields: [String] = []
    var methods: [String] = []
    /// 是否为显式声明(有文本/形状),用于区分"仅被边引用"的占位节点
    var declared = false
}

/// 流程图边。
struct FlowEdge: Equatable {
    var from: String
    var to: String
    var label: String?
    var style: MLineStyle = .solid
    var start: MArrow = .none
    var end: MArrow = .arrow
}

/// 子图(subgraph / 复合状态)。
struct FlowSub: Equatable {
    var id: String
    var title: String
    var parent: String?
    var members: [String] = []
    var children: [String] = []
}

/// 解析后的流程图。
struct FlowModel: Equatable {
    var direction: MDirection = .topDown
    var nodes: [String: FlowNode] = [:]
    var nodeOrder: [String] = []
    var edges: [FlowEdge] = []
    var subs: [String: FlowSub] = [:]
    var subOrder: [String] = []

    /// 取得或创建节点(用于边引用的占位)。
    mutating func ensureNode(_ id: String, parent: String?) {
        if nodes[id] == nil {
            nodes[id] = FlowNode(id: id, text: id)
            nodeOrder.append(id)
            if let parent { subs[parent]?.members.append(id) }
        } else if let parent, !isMember(id) {
            subs[parent]?.members.append(id)
        }
    }

    /// 声明节点(带文本/形状)。
    mutating func declare(_ id: String, text: String, shape: MShape, parent: String?) {
        ensureNode(id, parent: parent)
        nodes[id]?.text = text
        nodes[id]?.shape = shape
        nodes[id]?.declared = true
    }

    /// 节点是否已归属某个子图。
    func isMember(_ id: String) -> Bool {
        subs.values.contains { $0.members.contains(id) }
    }

    /// 新建子图。若同名占位节点已存在则移除(边引用将解析到子图成员)。
    mutating func addSub(id: String, title: String, parent: String?) {
        if nodes[id] != nil {
            nodes[id] = nil
            nodeOrder.removeAll { $0 == id }
            for key in subs.keys { subs[key]?.members.removeAll { $0 == id } }
        }
        subs[id] = FlowSub(id: id, title: title, parent: parent)
        subOrder.append(id)
        if let parent { subs[parent]?.children.append(id) }
    }

    /// 解析边端点:若指向子图,取其第一个(递归)成员节点。
    func resolveEndpoint(_ id: String) -> String? {
        if nodes[id] != nil { return id }
        guard let sub = subs[id] else { return nil }
        for member in sub.members { return member }
        for child in sub.children { if let r = resolveEndpoint(child) { return r } }
        return nil
    }

    /// 节点所在的子图链(由内到外)。
    func chain(of node: String) -> [String] {
        guard var current = subs.values.first(where: { $0.members.contains(node) })?.id else { return [] }
        var result = [current]
        while let parent = subs[current]?.parent { result.append(parent); current = parent }
        return result
    }
}
