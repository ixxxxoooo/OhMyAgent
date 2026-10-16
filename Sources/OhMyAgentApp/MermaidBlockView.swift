// @author ixxxxoooo
// Mermaid 代码块:原生渲染图(MermaidKit),支持复制源码、下载(PNG/PDF/源码)、点击在悬浮窗中放大;解析失败时回退为源码并提示原因。

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
enum MermaidResult: Sendable {
    case scene(MScene, kind: MermaidKind)
    case failure(MermaidError)
}

/// 离线线程解析与布局。
func renderMermaid(_ source: String) async -> MermaidResult {
    if let cached = await MermaidSceneCache.cached(source) { return cached }
    let result = await Task.detached(priority: .userInitiated) { () -> MermaidResult in
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
    // 只缓存成功的场景(失败可能是流式输出尚未完整)
    if case .scene = result { await MermaidSceneCache.store(result, for: source) }
    return result
}

/// 聊天内的 Mermaid 图块。
struct MermaidBlockView: View {
    let source: String
    @Environment(\.colorScheme) private var scheme
    @State private var result: MermaidResult?
    @State private var showSource = false
    @State private var copied = false

    init(source: String) {
        self.source = source
        // 重新挂载(切换标签/会话、滚动回来)时直接用缓存,避免先空白再出图
        _result = State(initialValue: MermaidSceneCache.cached(source))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .omSolidCard(cornerRadius: 10)
        .task(id: source) { if result == nil || !isCached { result = await renderMermaid(source) } }
    }

    private var isCached: Bool { MermaidSceneCache.cached(source) != nil }

    private var header: some View {
        HStack(spacing: 10) {
            Label("Mermaid", om: "workflow", size: 12)
                .font(OMFonts.caption)
                .foregroundStyle(OMColors.secondaryText)
            Spacer()
            if case .scene = result {
                headerButton("code", help: showSource ? "查看图" : "查看源码") { showSource.toggle() }
                downloadMenu
                headerButton("maximize-2", help: "放大查看(悬浮窗,可拖动缩放)") { openFloating() }
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

    /// 下载菜单(PNG / PDF / 源码)。
    private var downloadMenu: some View {
        Menu {
            ForEach(MermaidExportFormat.allCases, id: \.self) { format in
                Button(format.title) { download(format) }
            }
        } label: {
            Image.om("download", size: 13)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .foregroundStyle(OMColors.secondaryText)
        .fixedSize()
        .help("下载")
        .accessibilityLabel("下载")
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
                    .contentShape(Rectangle())
                    .onTapGesture { openFloating() }
                    .onHover { inside in if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
                    .help("点击放大查看")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel("Mermaid 图表,点击放大查看")
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

    /// 下载指定格式。
    private func download(_ format: MermaidExportFormat) {
        guard case .scene(let scene, _) = result else { return }
        MermaidExport.save(format, scene: scene, source: source, dark: scheme == .dark)
    }

    /// 以悬浮窗放大查看(当前页内,不新开标签)。
    private func openFloating() {
        MermaidFloatingStore.shared.present(source: source)
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
