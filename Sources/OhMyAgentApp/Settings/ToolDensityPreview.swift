// @author ixxxxoooo
// 外观页「工具调用详细程度」的示例预览:随档位切换精简摘要 / 标准单行 / 详细内联 Diff。

import ChatKit
import DesignSystem
import IconKit
import SwiftUI

/// 工具调用详细程度的示例预览卡。
struct ToolDensityPreview: View {
    let density: ToolDensity

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch density {
            case .compact:
                summaryRow(String(localized: "编辑了 2 个文件、运行了 2 条命令"), icon: "layers")
            case .standard:
                sampleRow(icon: "pencil", verb: String(localized: "编辑"), subject: "math.ts", stats: "+4 −1")
                sampleRow(icon: "pencil", verb: String(localized: "编辑"), subject: "README.md", stats: "+5 −1")
                sampleRow(icon: "terminal", verb: String(localized: "运行"), subject: "focused tests", stats: "npm test")
                sampleRow(icon: "terminal", verb: String(localized: "运行"), subject: "type-check", stats: "npm run")
            case .detailed:
                sampleRow(icon: "pencil", verb: String(localized: "编辑"), subject: "math.ts", stats: "+4 −1")
                diffBars
                sampleRow(icon: "terminal", verb: String(localized: "运行"), subject: "focused tests", stats: "npm test")
                outputBars
            }
        }
        .padding(OMSpacing.sm + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(OMColors.surface, in: RoundedRectangle(cornerRadius: OMRadius.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: OMRadius.control, style: .continuous).strokeBorder(OMColors.hairline, lineWidth: 0.5))
        .animation(OMMotion.standard, value: density)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("工具调用详细程度预览"))
    }

    private func summaryRow(_ text: String, icon: String) -> some View {
        HStack(spacing: 7) {
            Image.om(icon, size: 11.5).foregroundStyle(OMColors.secondaryText).frame(width: 16)
            Text(verbatim: text).font(OMFonts.small).foregroundStyle(OMColors.secondaryText)
        }
    }

    private func sampleRow(icon: String, verb: String, subject: String, stats: String) -> some View {
        HStack(spacing: 7) {
            Image.om(icon, size: 11.5).foregroundStyle(OMColors.secondaryText).frame(width: 16)
            Text(verbatim: verb).font(OMFonts.small).foregroundStyle(OMColors.secondaryText)
            Text(verbatim: subject).font(OMFonts.small).foregroundStyle(OMColors.primaryText)
            Text(verbatim: stats).font(OMFonts.caption).foregroundStyle(OMColors.tertiaryText)
        }
    }

    /// 内联 Diff 示意:两条删除线 + 两条新增线。
    private var diffBars: some View {
        VStack(spacing: 2) {
            bar(OMDiffPalette.background(.removed), width: 1)
            bar(OMDiffPalette.background(.removed), width: 0.7)
            bar(OMDiffPalette.background(.added), width: 1)
            bar(OMDiffPalette.background(.added), width: 0.7)
        }
        .padding(.leading, 23)
    }

    /// 命令输出示意:两条灰线。
    private var outputBars: some View {
        VStack(spacing: 2) {
            bar(OMColors.subtleFill, width: 1)
            bar(OMColors.subtleFill, width: 0.55)
        }
        .padding(.leading, 23)
    }

    private func bar(_ color: Color, width: CGFloat) -> some View {
        GeometryReader { proxy in
            RoundedRectangle(cornerRadius: OMRadius.tag, style: .continuous)
                .fill(color)
                .frame(width: proxy.size.width * width, height: 6)
        }
        .frame(height: 6)
    }
}
