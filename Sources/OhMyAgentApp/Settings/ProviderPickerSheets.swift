// @author ixxxxoooo
// 提供商设置的两个面板:「获取模型列表」勾选面板、「从 OpenCode 导入」确认面板。

import ChatKit
import DesignSystem
import IconKit
import SwiftUI

/// 获取模型列表并勾选加入。
struct ModelFetchSheet: View {
    let provider: ModelProvider
    let key: String
    /// 已在清单中的模型 ID
    let existing: Set<String>
    let onConfirm: ([String]) -> Void
    let onCancel: () -> Void

    @State private var ids: [String] = []
    @State private var selected: Set<String> = []
    @State private var query = ""
    @State private var loading = true
    @State private var errorMessage: String?

    private var visible: [String] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        return needle.isEmpty ? ids : ids.filter { $0.lowercased().contains(needle) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("获取模型列表").font(OMFonts.title)
            HStack(spacing: 6) {
                Image.om("search", size: 12).foregroundStyle(OMColors.tertiaryText)
                TextField("搜索模型", text: $query).textFieldStyle(.plain)
            }
            .padding(.horizontal, 8).frame(height: 26)
            .background(RoundedRectangle(cornerRadius: OMRadius.control).fill(OMColors.hoverFill))
            content
            HStack {
                Button("全选") { selected.formUnion(visible.filter { !existing.contains($0) }) }.disabled(visible.isEmpty)
                Button("全不选") { selected.subtract(visible) }.disabled(visible.isEmpty)
                Spacer()
                Button("取消", action: onCancel).keyboardShortcut(.cancelAction)
                Button("添加所选(\(selected.count))") { onConfirm(ids.filter { selected.contains($0) }) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 440, height: 480)
        .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if loading {
            HStack { Spacer(); OMSpinner(.regular); Spacer() }.frame(maxHeight: .infinity)
        } else if let errorMessage {
            VStack(spacing: 8) {
                Label(errorMessage, om: "xmark.octagon.fill").foregroundStyle(OMColors.danger).fixedSize(horizontal: false, vertical: true)
                Button("重试") { Task { await load() } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(visible, id: \.self) { id in
                HStack {
                    Toggle(isOn: Binding(get: { selected.contains(id) || existing.contains(id) }, set: { on in
                        if on { selected.insert(id) } else { selected.remove(id) }
                    })) {
                        HStack(spacing: 6) {
                            BrandIconView(BrandIcon.resolve(modelId: id, providerPreset: provider.presetId, providerName: provider.name), size: 14)
                            Text(id).font(OMFonts.monoSmall)
                        }
                    }
                    .toggleStyle(.checkbox)
                    .disabled(existing.contains(id))
                    ModelCopyButton(text: id)
                    Spacer()
                    if existing.contains(id) { OMTag(String(localized: "已添加")) }
                }
            }
            .listStyle(.inset)
        }
    }

    private func load() async {
        loading = true
        errorMessage = nil
        switch await ProviderModelFetcher.fetch(provider, key: key) {
        case .success(let list):
            ids = list
        case .failure(let error):
            errorMessage = error.message
        }
        loading = false
    }
}

/// 从 OpenCode 导入:先列出摘要(不读取密钥),确认后才读取并写入密钥。
struct OpenCodeImportSheet: View {
    let model: ProviderSettingsModel
    let onClose: () -> Void

    @State private var candidates: [OpenCodeImporter.Candidate] = []
    @State private var excluded: Set<String> = []
    @State private var done: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("从 OpenCode 导入").font(OMFonts.title)
            Note("读取 ~/.config/opencode 里的提供商、地址与模型。点「导入」后才会读取并保存对应的 API Key(保存在 OhMyAgent 自己的 0600 文件中),密钥不会显示或写入日志。")
            if candidates.isEmpty {
                Text("没有找到可导入的 OpenCode 配置。").font(OMFonts.body).foregroundStyle(OMColors.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(candidates) { item in
                    HStack {
                        Toggle("", isOn: Binding(get: { !excluded.contains(item.id) }, set: { on in
                            if on { excluded.remove(item.id) } else { excluded.insert(item.id) }
                        })).labelsHidden().toggleStyle(.checkbox)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.provider.name).font(OMFonts.body)
                            Text("\(item.provider.baseURL) · \(item.provider.modelList.count) 个模型").font(OMFonts.caption).foregroundStyle(OMColors.tertiaryText)
                        }
                        Spacer()
                        OMTag(item.hasKey ? String(localized: "含密钥") : String(localized: "无密钥"), tint: item.hasKey ? .green : OMColors.secondaryText)
                    }
                }
                .listStyle(.inset)
            }
            if let done { Label("已导入 \(done) 个提供商", om: "checkmark.circle").font(OMFonts.small).foregroundStyle(OMColors.secondaryText) }
            HStack {
                Spacer()
                Button(done == nil ? "取消" : "完成", action: onClose).keyboardShortcut(.cancelAction)
                Button("导入") {
                    Task {
                        // 确认后才读取密钥(后台读盘)
                        let loaded = await Task.detached { OpenCodeImporter.load() }.value
                        done = OpenCodeImporter.importAll(loaded.filter { !excluded.contains($0.id) }, into: model)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(candidates.isEmpty || candidates.count == excluded.count || done != nil)
            }
        }
        .padding(16)
        .frame(width: 460, height: 400)
        .task { candidates = await Task.detached { OpenCodeImporter.scan() }.value }
    }
}
