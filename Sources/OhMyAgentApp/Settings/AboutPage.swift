// @author ixxxxoooo
// 设置页:关于(应用版本与更新)。

import AppKit
import ChatKit
import DesignSystem
import SwiftUI
import WorkbenchKit

/// 关于:应用名称、版本与更新设置。
struct AboutPage: View {
    @AppStorage(ClientPrefs.Key.autoUpdate) private var autoUpdate = true
    @AppStorage(ClientPrefs.Key.updateMode) private var updateMode = UpdateMode.download.rawValue
    @State private var updates = UpdateModel.shared

    /// 更新检查状态文案。
    @ViewBuilder
    private var updateStatus: some View {
        switch updates.state {
        case .idle: EmptyView()
        case .checking: OMSpinner(.small)
        case .result(.upToDate): Text("已是最新版本").foregroundStyle(OMColors.secondaryText)
        case .result(.available(let info)):
            switch updates.phase {
            case .ready: Button("更新") { updates.installAndRestart() }
            case .downloading(let value): Text("下载中 \(Int(value * 100))%").foregroundStyle(OMColors.secondaryText)
            default: Button("下载并更新 \(info.version)") { updates.performPrimaryAction() }
            }
            if let notes = info.notes { Text(notes).foregroundStyle(OMColors.secondaryText).lineLimit(1) }
        case .result(.unsupportedSystem(let info)): Text("\(info.version) 需要 macOS \(info.minimumSystemVersion ?? "")").foregroundStyle(OMColors.warning)
        case .result(.failed(let message)): Text(message).foregroundStyle(OMColors.danger).lineLimit(2)
        }
    }

    var body: some View {
        SettingsForm {
            Section {
                AboutHeader(version: updates.currentVersion, build: updates.currentBuild)
            }
            Section("更新") {
                Toggle("自动检查更新", isOn: $autoUpdate)
                Picker("更新方式", selection: $updateMode) {
                    Text("仅提醒").tag(UpdateMode.remind.rawValue)
                    Text("自动下载").tag(UpdateMode.download.rawValue)
                    Text("自动下载并在最佳时间安装").tag(UpdateMode.auto.rawValue)
                }
                Note("自动下载只在网络不计费(非热点/低数据模式)时进行;最佳安装时间:电脑空闲 15 分钟以上且没有会话在运行,或下次退出应用时。侧栏的「更新」按钮可随时手动触发。")
                HStack {
                    Button("立即检查") { updates.checkNow() }.disabled(updates.state == .checking)
                    updateStatus
                }
                Note("更新来自 GitHub 最新正式版。开发版只下载、不替换自身。")
            }
        }
    }
}

/// 关于页顶部:应用图标(logo)、名称、版本与简介。
private struct AboutHeader: View {
    let version: String
    let build: Int

    var body: some View {
        HStack(spacing: OMSpacing.lg) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 72, height: 72)
                .accessibilityLabel("OhMyAgent 图标")
            VStack(alignment: .leading, spacing: OMSpacing.xs) {
                Text(verbatim: "OhMyAgent").font(OMFonts.title).foregroundStyle(OMColors.primaryText)
                Text("版本 \(version) (\(build))").font(OMFonts.small).foregroundStyle(OMColors.secondaryText)
                Text("原生 macOS 的 Agent 工作台,通过 ACP 接管本机已安装的 Claude Code。")
                    .font(OMFonts.small).foregroundStyle(OMColors.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, OMSpacing.sm)
    }
}
