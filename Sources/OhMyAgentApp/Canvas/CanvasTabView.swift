// @author ixxxxoooo
// Canvas 标签页:顶部工具栏(标题、渲染/源码切换、刷新、复制源码、导出 PNG),下方为块渲染或 JSON 源码。
// Agent 通过 Bridge 更新画布后,`CanvasHub` 的修订号变化会触发重新读盘。

import AppKit
import CanvasKit
import ChatKit
import DesignSystem
import IconKit
import OMLog
import SwiftUI
import WorkbenchKit

/// 工具栏视图模式。
enum CanvasViewMode: Hashable { case render, source }

struct CanvasTabView: View {
    let canvasID: String
    @State private var document: CanvasDocument?
    @State private var errorText: String?
    @State private var mode = CanvasViewMode.render
    @State private var loading = true
    private let hub = CanvasHub.shared

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().opacity(0.5)
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(OMColors.surface)
        .task(id: hub.revision(of: canvasID)) { await load() }
    }

    // MARK: 工具栏

    private var toolbar: some View {
        HStack(spacing: 10) {
            Image.om("chart-column", size: 14).foregroundStyle(OMColors.accent)
            Text(verbatim: document?.title ?? canvasID).font(OMFonts.title).lineLimit(1)
            if let document {
                Text("第 \(document.revision) 版 · \(document.blockCount) 个块").font(OMFonts.caption).foregroundStyle(OMColors.tertiaryText)
            }
            Spacer(minLength: 8)
            OMCompactSegmented(
                options: [(value: CanvasViewMode.render, title: String(localized: "渲染")), (value: CanvasViewMode.source, title: String(localized: "源码"))],
                selection: mode, accessibilityName: String(localized: "画布视图模式")
            ) { mode = $0 }
            toolButton("rotate-cw", help: "重新读取") { Task { await load() } }
            OMCopyButton(help: String(localized: "复制画布源码")) { document.map(CanvasStore.source(of:)) }
                .buttonStyle(.omIcon)
            toolButton("download", help: "导出为 PNG") { exportPNG() }
        }
        .padding(.horizontal, 16)
        .frame(height: 40)
    }

    private func toolButton(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image.om(icon, size: 13) }
            .buttonStyle(.omIcon)
            .omTooltip(help)
            .accessibilityLabel(help)
            .disabled(document == nil)
    }

    // MARK: 内容

    @ViewBuilder
    private var content: some View {
        if let document {
            ScrollView {
                Group {
                    switch mode {
                    case .render: CanvasBodyView(document: document)
                    case .source:
                        Text(verbatim: CanvasStore.source(of: document))
                            .font(OMFonts.monoSmall).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 28).padding(.vertical, 20)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .scrollContentBackground(.hidden)
        } else if let errorText {
            VStack(spacing: 8) {
                Image.om("triangle-alert", size: 24).foregroundStyle(OMColors.tertiaryText)
                Text(verbatim: errorText).font(OMFonts.body).foregroundStyle(OMColors.secondaryText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if loading {
            OMSpinner(.regular).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: 动作

    /// 后台读盘(不阻塞主线程)。
    private func load() async {
        let id = canvasID
        let started = Date()
        let result: Result<CanvasDocument, CanvasError> = await Task.detached(priority: .userInitiated) {
            do { return .success(try CanvasStore.app.load(id: id)) }
            catch let error as CanvasError { return .failure(error) }
            catch { return .failure(CanvasError(error.localizedDescription)) }
        }.value
        loading = false
        switch result {
        case .success(let value):
            document = value
            errorText = nil
            Log.ui.info("Canvas 已加载", ["canvasId": id, "blocks": "\(value.blockCount)", "ms": "\(Int(Date().timeIntervalSince(started) * 1000))"])
        case .failure(let error):
            if document == nil { errorText = error.message }
            Log.ui.warning("Canvas 加载失败", ["canvasId": id, "error": error.message])
        }
    }

    /// 导出整张画布为 PNG(离屏渲染,宽 820)。
    private func exportPNG() {
        guard let document else { return }
        let view = CanvasBodyView(document: document)
            .padding(28).frame(width: 820, alignment: .leading)
            .background(OMColors.surface)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let data = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
            Log.ui.warning("Canvas 导出 PNG 失败", ["canvasId": canvasID])
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(document.title).png"
        panel.allowedContentTypes = [.png]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try data.write(to: url, options: .atomic) } catch {
            Log.ui.error("Canvas 写出 PNG 失败", error: error)
        }
    }
}

/// 工具行下方的「画布卡片」:显示标题与摘要,点击在标签页打开。
struct CanvasCardView: View {
    let ref: CanvasToolRef
    @Environment(SessionModel.self) private var model
    @State private var summary: CanvasSummary?
    @State private var hovering = false

    var body: some View {
        Button { open() } label: {
            HStack(spacing: 10) {
                Image.om("chart-column", size: 16).foregroundStyle(OMColors.accent)
                    .frame(width: 32, height: 32)
                    .background(OMColors.selectedFill, in: RoundedRectangle(cornerRadius: OMRadius.control, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: summary?.title ?? ref.title ?? ref.canvasID).font(OMFonts.body.weight(.medium)).lineLimit(1)
                    Text(ref.isUpdate ? "已更新画布 · 点击打开" : "画布 · 点击打开")
                        .font(OMFonts.caption).foregroundStyle(OMColors.secondaryText)
                }
                Spacer(minLength: 8)
                Image.om("square-arrow-out-up-right", size: 12).foregroundStyle(OMColors.tertiaryText)
            }
            .padding(10)
            .frame(maxWidth: 420, alignment: .leading)
            .background(hovering ? OMColors.subtleFill : OMColors.card, in: RoundedRectangle(cornerRadius: OMMetrics.cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: OMMetrics.cardRadius, style: .continuous).strokeBorder(OMColors.hairline, lineWidth: 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(String(localized: "打开画布 \(summary?.title ?? ref.canvasID)"))
        .task(id: ref.canvasID) {
            let id = ref.canvasID
            summary = await Task.detached(priority: .utility) { CanvasStore.app.list().first { $0.id == id } }.value
        }
    }

    private func open() {
        AppEnvironment.shared.workbench.openCanvas(id: ref.canvasID, title: summary?.title ?? ref.title ?? String(localized: "画布"))
    }
}
