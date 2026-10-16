// @author ixxxxoooo
// Mermaid 代码块:原生渲染图(MermaidKit),支持复制源码、导出 PNG、在标签中放大;解析失败时回退为源码并提示原因。

import AppKit
import DesignSystem
import IconKit
import MermaidKit
import OMLog
import SwiftUI

/// 放大预览所用的内容仓库(预览标签只存标识,内容在此查找;不持久化)。
@MainActor
@Observable
final class MermaidPreviewStore {
    static let shared = MermaidPreviewStore()
    private(set) var sources: [String: String] = [:]

    /// 登记源码并返回稳定标识(同源码同标识)。
    func register(_ source: String) -> String {
        let id = "mermaid-\(abs(source.hashValue))"
        sources[id] = source
        return id
    }
}

/// 渲染结果。
private enum MermaidResult: Sendable {
    case scene(MScene, kind: MermaidKind)
    case failure(MermaidError)
}

/// 离线线程解析与布局。
private func renderMermaid(_ source: String) async -> MermaidResult {
    await Task.detached(priority: .userInitiated) {
        let started = Date()
        do {
            let kind = try Mermaid.kind(of: source)
            let scene = try Mermaid.scene(for: source)
            Log.ui.debug("Mermaid 渲染", ["kind": kind.rawValue, "ms": "\(Int(Date().timeIntervalSince(started) * 1000))"])
            return .scene(scene, kind: kind)
        } catch let error as MermaidError {
            Log.ui.warning("Mermaid 渲染失败", ["error": error.description])
            return .failure(error)
        } catch {
            Log.ui.warning("Mermaid 渲染失败", ["error": error.localizedDescription])
            return .failure(MermaidError(error.localizedDescription))
        }
    }.value
}

/// 聊天内的 Mermaid 图块。
struct MermaidBlockView: View {
    let source: String
    @Environment(\.colorScheme) private var scheme
    @State private var result: MermaidResult?
    @State private var showSource = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .omSolidCard(cornerRadius: 10)
        .task(id: source) { result = await renderMermaid(source) }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Label("Mermaid", om: "workflow", size: 12)
                .font(OMFonts.caption)
                .foregroundStyle(OMColors.secondaryText)
            Spacer()
            if case .scene = result {
                headerButton("code", help: showSource ? "查看图" : "查看源码") { showSource.toggle() }
                headerButton("image", help: "导出 PNG") { exportPNG() }
                headerButton("square-arrow-out-up-right", help: "在标签中放大") { openInTab() }
            }
            headerButton(copied ? "checkmark" : "doc.on.doc", help: "复制源码") { copySource() }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func headerButton(_ symbol: String, help: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image.om(symbol, size: 13) }
            .buttonStyle(.plain)
            .foregroundStyle(OMColors.secondaryText)
            .help(help)
            .accessibilityLabel(Text(help))
    }

    @ViewBuilder
    private var content: some View {
        switch result {
        case .none:
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 80)
        case .scene(let scene, _):
            if showSource { sourceView } else {
                MermaidCanvas(scene: scene)
                    .padding(12)
                    .frame(maxWidth: .infinity)
                    .background(MermaidPalette(dark: scheme == .dark).background)
            }
        case .failure(let error):
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Image.om("exclamationmark.triangle", size: 12).foregroundStyle(OMColors.warning)
                    Text("无法渲染此图:\(error.description)").font(OMFonts.caption).foregroundStyle(OMColors.secondaryText)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                sourceView
            }
        }
    }

    private var sourceView: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(source).font(OMFonts.readingMono).padding(12).fixedSize(horizontal: true, vertical: true)
        }
    }

    private func copySource() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(source, forType: .string)
        copied = true
        Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
    }

    private func exportPNG() {
        guard case .scene(let scene, _) = result else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "mermaid.png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = MermaidRenderer.pngData(scene, dark: scheme == .dark) else {
            Log.ui.warning("Mermaid 导出 PNG 失败:渲染为空", [:])
            return
        }
        Task.detached {
            do { try data.write(to: url); Log.ui.info("Mermaid 已导出", ["file": url.lastPathComponent, "bytes": "\(data.count)"]) }
            catch { Log.ui.error("Mermaid 导出写入失败", ["error": error.localizedDescription]) }
        }
    }

    private func openInTab() {
        let id = MermaidPreviewStore.shared.register(source)
        AppActions.shared.openPreview(id: id, title: String(localized: "Mermaid 图"))
    }
}

/// 预览标签:默认适应窗口(可放大至 2 倍),也可切换为实际大小并滚动查看。
struct PreviewTabView: View {
    let id: String
    @State private var result: MermaidResult?
    @State private var fit = true
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Picker("缩放", selection: $fit) {
                    Text("适应窗口").tag(true)
                    Text("实际大小").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 180)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            Divider()
            switch result {
            case .none: ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .scene(let scene, _): sceneView(scene)
            case .failure(let error):
                Text(error.description).foregroundStyle(OMColors.secondaryText).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            guard let source = MermaidPreviewStore.shared.sources[id] else {
                result = .failure(MermaidError(String(localized: "预览内容已失效")))
                return
            }
            result = await renderMermaid(source)
        }
    }

    @ViewBuilder
    private func sceneView(_ scene: MScene) -> some View {
        let background = MermaidPalette(dark: scheme == .dark).background
        if fit {
            GeometryReader { geo in
                let scale = min(2, max(0.1, min((geo.size.width - 32) / scene.size.width, (geo.size.height - 32) / scene.size.height)))
                MermaidCanvas(scene: scene, fitWidth: false)
                    .scaleEffect(scale)
                    .frame(width: scene.size.width * scale, height: scene.size.height * scale)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }
            .background(background)
        } else {
            ScrollView([.horizontal, .vertical]) {
                MermaidCanvas(scene: scene, fitWidth: false).padding(16)
            }
            .background(background)
        }
    }
}
