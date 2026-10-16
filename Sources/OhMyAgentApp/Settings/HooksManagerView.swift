// @author ixxxxoooo
// Hooks 管理:事件 → matcher → 处理器 的分组视图;设置层的 Hook 可增删改,插件 Hook 只读。

import IconKit
import ClaudeConfigKit
import DesignSystem
import SwiftUI

/// Hooks 管理页。
struct HooksManagerView: View {
    let center: ConfigCenter
    @State private var editor: HookEditorTarget?
    @State private var pendingDelete: HookEntry?

    private var grouped: [(String, [HookEntry])] {
        let groups = Dictionary(grouping: center.snapshot.hooks, by: \.event)
        return groups.keys.sorted().map { ($0, groups[$0] ?? []) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { editor = HookEditorTarget(entry: nil) } label: { Label("添加 Hook", om: "plus") }
                Spacer()
                Text("来源:用户 / 项目 / 本地设置与已启用插件").font(OMFonts.caption).foregroundStyle(OMColors.secondaryText)
            }
            .padding(10)
            if grouped.isEmpty {
                EmptyHint(icon: "bolt.horizontal", title: String(localized: "没有配置 Hook"), message: String(localized: "Hook 可在工具调用前后、会话开始/结束等事件上运行命令。"))
            } else {
                List {
                    ForEach(grouped, id: \.0) { event, entries in
                        Section(event) { ForEach(entries) { row($0) } }
                    }
                }
                .listStyle(.inset)
            }
        }
        .sheet(item: $editor) { target in HookEditorSheet(center: center, target: target) { editor = nil } }
        .confirmationDialog("删除 Hook?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), presenting: pendingDelete) { entry in
            Button("删除", role: .destructive) { center.perform(String(localized: "已删除 Hook")) { try HooksStore(paths: center.paths).remove(entry) } }
        } message: { entry in
            Text("将从\(entry.origin.displayName)中移除。")
        }
    }

    private func row(_ entry: HookEntry) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Tag(entry.handler.type, color: OMColors.accent2)
                    if !entry.matcher.isEmpty { Tag(String(localized: "匹配 \(entry.matcher)")) }
                    Tag(entry.origin.displayName)
                    if let timeout = entry.handler.timeout { Tag("\(timeout)s") }
                }
                Text(entry.handler.summary).font(OMFonts.monoSmall).lineLimit(2).textSelection(.enabled)
            }
            Spacer()
            if case .settings = entry.origin {
                Button { editor = HookEditorTarget(entry: entry) } label: { Image.om("pencil") }.buttonStyle(.borderless).help("编辑").accessibilityLabel("编辑")
                Button { pendingDelete = entry } label: { Image.om("trash") }.buttonStyle(.borderless).help("删除").accessibilityLabel("删除")
            } else {
                Image.om("lock").foregroundStyle(OMColors.tertiaryText).help("来自插件,只读")
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// Hook 编辑目标。
struct HookEditorTarget: Identifiable {
    let id = UUID()
    let entry: HookEntry?
}

/// Hook 编辑表单。
struct HookEditorSheet: View {
    let center: ConfigCenter
    let target: HookEditorTarget
    let onClose: () -> Void

    @State private var event = "PreToolUse"
    @State private var matcher = ""
    @State private var scope: ConfigScope = .user
    @State private var type = "command"
    @State private var command = ""
    @State private var url = ""
    @State private var prompt = ""
    @State private var timeout = ""

    private var handler: HookHandler {
        HookHandler(type: type, command: command, url: url, prompt: prompt, timeout: Int(timeout))
    }

    private var problems: [String] {
        var result = HooksStore.validate(handler: handler, event: event, matcher: matcher)
        if !timeout.isEmpty, Int(timeout) == nil { result.append(String(localized: "超时需要是整数秒")) }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(target.entry == nil ? String(localized: "添加 Hook") : String(localized: "编辑 Hook")).font(OMFonts.title)
            FormRow(label: String(localized: "事件")) {
                Picker("", selection: $event) { ForEach(HooksStore.events, id: \.self) { Text($0).tag($0) } }.labelsHidden().fixedSize().disabled(target.entry != nil)
            }
            FormRow(label: String(localized: "匹配器"), hint: String(localized: "工具名或正则,如 Bash、Edit|Write;留空表示全部")) { TextField("", text: $matcher).textFieldStyle(.roundedBorder).font(OMFonts.mono) }
            if target.entry == nil {
                FormRow(label: String(localized: "写入位置")) {
                    Picker("", selection: $scope) { ForEach(ConfigScope.allCases) { Text($0.displayName).tag($0) } }.pickerStyle(.segmented).labelsHidden()
                }
            }
            FormRow(label: String(localized: "类型")) {
                Picker("", selection: $type) { ForEach(HooksStore.handlerTypes, id: \.self) { Text($0).tag($0) } }.labelsHidden().fixedSize()
            }
            switch type {
            case "command": FormRow(label: String(localized: "命令"), hint: String(localized: "通过 stdin 接收事件 JSON;退出码 2 表示阻止")) { TextField("", text: $command).textFieldStyle(.roundedBorder).font(OMFonts.mono) }
            case "http": FormRow(label: "URL") { TextField("https://", text: $url).textFieldStyle(.roundedBorder).font(OMFonts.mono) }
            case "prompt", "agent":
                FormRow(label: String(localized: "提示词")) { TextEditor(text: $prompt).font(OMFonts.mono).frame(height: 80).overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(OMColors.hairline)) }
            default: FormRow(label: String(localized: "命令")) { TextField("", text: $command).textFieldStyle(.roundedBorder).font(OMFonts.mono) }
            }
            FormRow(label: String(localized: "超时(秒)")) { TextField("默认", text: $timeout).textFieldStyle(.roundedBorder).frame(width: 90) }
            SheetFooter(problems: problems, confirmTitle: String(localized: "保存"), onCancel: onClose, onConfirm: save)
        }
        .padding(20)
        .frame(width: 560)
        .onAppear {
            guard let entry = target.entry else { return }
            event = entry.event
            matcher = entry.matcher
            type = entry.handler.type
            command = entry.handler.command
            url = entry.handler.url
            prompt = entry.handler.prompt
            timeout = entry.handler.timeout.map(String.init) ?? ""
        }
    }

    private func save() {
        let ok = center.perform(String(localized: "已保存 Hook")) {
            let store = HooksStore(paths: center.paths)
            if let entry = target.entry { try store.update(entry, handler: handler, matcher: matcher) }
            else { try store.add(handler, event: event, matcher: matcher, scope: scope) }
        }
        if ok { onClose() }
    }
}
