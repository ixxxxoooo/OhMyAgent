// @author ygw
// 底部面板:顶部可拖拽调整高度的分隔条 + 标签(输出,后续加入终端与问题)+ 内容。

import IconKit
import ChatKit
import DesignSystem
import SwiftUI
import WorkbenchKit

struct BottomPanelView: View {
    @Bindable var workbench: WorkbenchModel
    @State private var dragStartHeight: Double?

    var body: some View {
        VStack(spacing: 0) {
            resizeHandle
            HStack(spacing: 4) {
                ForEach(BottomPane.available, id: \.self) { pane in
                    Button(Self.title(pane)) { workbench.layout.bottomPane = pane }
                        .buttonStyle(.plain)
                        .font(OMFonts.small.weight(workbench.layout.bottomPane == pane ? .semibold : .regular))
                        .foregroundStyle(workbench.layout.bottomPane == pane ? Color.primary : OMColors.secondaryText)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(workbench.layout.bottomPane == pane ? OMColors.accent.opacity(0.12) : .clear, in: Capsule())
                }
                Spacer()
                Button { workbench.layout.bottomVisible = false } label: { Image.om("xmark") }
                    .buttonStyle(.borderless)
                    .help("关闭面板 (\(ShortcutStore.shared.binding(for: .togglePanel).display))")
                    .accessibilityLabel("关闭底部面板")
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            Divider()
            Group {
                switch workbench.layout.bottomPane {
                case .output: LogViewerView()
                case .terminal, .problems: EmptyView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: CGFloat(workbench.layout.bottomHeight))
        .background(OMColors.surface)
    }

    /// 顶部 1pt 分隔线 + 5pt 高的拖拽热区。
    private var resizeHandle: some View {
        Rectangle()
            .fill(OMColors.hairline)
            .frame(height: 1)
            .overlay {
                Color.clear.frame(height: 7).contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
                    }
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { value in
                            let start = dragStartHeight ?? workbench.layout.bottomHeight
                            dragStartHeight = start
                            workbench.layout.bottomHeight = min(max(start - value.translation.height, 120), 600)
                        }
                        .onEnded { _ in dragStartHeight = nil })
            }
    }

    private static func title(_ pane: BottomPane) -> String {
        switch pane {
        case .terminal: return String(localized: "终端")
        case .output: return String(localized: "输出")
        case .problems: return String(localized: "问题")
        }
    }
}
