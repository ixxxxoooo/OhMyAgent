// @author ixxxxoooo
// 设置页「官方 Agent」分区:Google Antigravity 的一键安装/升级/卸载、默认模型与登录指引。
// 点击「安装」前不会联网下载;下载源仅限 Google 官方域名(见 AgentInstaller 白名单)。

import AgentHost
import ChatKit
import DesignSystem
import IconKit
import SwiftUI

/// Google Antigravity 一键安装分区。
struct AntigravityInstallSection: View {
    @State private var model = AgentInstallModel.shared
    @State private var modelDraft = ""

    var body: some View {
        Section("官方 Agent") {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    BrandIconView(BrandIcon.resolve(providerPreset: nil, providerName: "Google Antigravity"), size: 14)
                    Text("Google Antigravity")
                    if let installed = model.installed { OMTag("v\(installed.version)") }
                    if model.updateAvailable { OMTag(String(localized: "可升级到 v\(model.latest.version)")) }
                }
                Note("Google 官方 ACP 服务端(agy_acp_server)。点击安装后从 Google 官方域名下载约数十 MB 的程序到应用目录,无需 Node.js。首次使用需在本机完成 Antigravity 登录。")
                statusRow
                actionRow
            }
            if model.installed != nil {
                LabeledContent("默认模型") {
                    TextField("留空使用官方默认", text: $modelDraft)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 240)
                        .onSubmit { model.setDefaultModel(modelDraft) }
                }
                Note("写入环境变量 AGY_ACP_DEFAULT_MODEL;按回车保存,对新开的会话生效。")
            }
        }
        .task {
            model.refresh()
            modelDraft = model.defaultModel
        }
    }

    /// 状态/进度/错误行。
    @ViewBuilder private var statusRow: some View {
        switch model.phase {
        case .checking:
            Note("正在检查最新版本…")
        case .working(let progress):
            HStack(spacing: 8) {
                switch progress {
                case .downloading(let fraction):
                    if let fraction { ProgressView(value: fraction).frame(maxWidth: 200) } else { ProgressView().controlSize(.small) }
                    Note("正在下载…")
                case .extracting:
                    ProgressView().controlSize(.small)
                    Note("正在解压…")
                case .finalizing:
                    ProgressView().controlSize(.small)
                    Note("正在完成安装…")
                }
            }
        case .failed(let message):
            Label(message, om: "exclamationmark.triangle").font(OMFonts.caption).foregroundStyle(OMColors.warning)
        case .idle:
            if !model.platformSupported {
                Label(String(localized: "当前平台暂无官方发行包"), om: "exclamationmark.triangle").font(OMFonts.caption).foregroundStyle(OMColors.warning)
            }
        }
    }

    /// 操作按钮行。
    private var actionRow: some View {
        HStack(spacing: 8) {
            if model.isWorking {
                Button("取消") { model.cancel() }
            } else if model.installed == nil {
                Button("一键安装") { model.install() }.buttonStyle(.omPrimary).disabled(!model.platformSupported)
            } else {
                if model.updateAvailable { Button("升级") { model.install() }.buttonStyle(.omPrimary) }
                Button("卸载", role: .destructive) { model.uninstall() }
            }
        }
        .controlSize(.small)
    }
}
