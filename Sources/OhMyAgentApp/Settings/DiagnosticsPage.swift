// @author ygw
// 设置页:诊断(进程资源、启动耗时、claude doctor、脱敏导出)。

import AgentHost
import AppKit
import ChatKit
import ClaudeConfigKit
import DesignSystem
import SwiftUI

/// 子进程资源行。
struct ProcessRow: Identifiable, Equatable {
    var id: Int32
    var name: String
    var rssMB: Double
    var cpu: Double
}

/// 诊断。
struct DiagnosticsPage: View {
    let center: ConfigCenter
    @AppStorage(ClientPrefs.Key.redactLogs) private var redact = true
    @State private var rows: [ProcessRow] = []
    @State private var doctorOutput: String?
    @State private var doctorRunning = false
    @State private var exportMessage: String?

    var body: some View {
        SettingsForm {
            Section("启动耗时") {
                LabeledContent("启动到首帧", value: DiagnosticsStore.shared.firstFrameMilliseconds.map { "\($0) ms" } ?? "未记录")
                if let model = SessionRegistry.shared.models.first {
                    LabeledContent("Agent 连接", value: model.connectDuration.map { "\($0.components.seconds * 1000 + $0.components.attoseconds / 1_000_000_000_000_000) ms" } ?? "未连接")
                }
            }
            Section("进程资源") {
                ForEach(rows) { row in
                    LabeledContent("\(row.name) (\(row.id))") { Text(String(format: "%.0f MB · CPU %.1f%%", row.rssMB, row.cpu)).monospacedDigit() }
                }
                if rows.isEmpty { Text("正在读取…").foregroundStyle(OMColors.secondaryText) }
            }
            Section("claude doctor") {
                HStack {
                    Button("运行检查") { Task { await runDoctor() } }.disabled(doctorRunning || !center.canRunCLI)
                    if doctorRunning { ProgressView().controlSize(.small) }
                }
                if let doctorOutput {
                    ScrollView { Text(doctorOutput).font(OMFonts.monoSmall).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                        .frame(maxHeight: 180)
                }
            }
            Section("导出") {
                HStack {
                    Button("导出诊断包…") { Task { await export() } }
                    Text(redact ? "已启用脱敏" : "未脱敏").font(OMFonts.small).foregroundStyle(OMColors.secondaryText)
                }
                if let exportMessage { Note(exportMessage) }
                Note("诊断包包含版本、工具路径、配置概要(仅键名)、最近 Agent 日志与计时,不含对话内容与凭据。")
            }
        }
        .task { await pollProcesses() }
    }

    /// 周期读取本应用及子进程的资源占用,视图消失时任务被取消。
    private func pollProcesses() async {
        while !Task.isCancelled {
            rows = await Self.sampleProcesses()
            try? await Task.sleep(for: .seconds(2))
        }
    }

    /// 通过 `ps` 采样当前进程及其后代进程。
    static func sampleProcesses() async -> [ProcessRow] {
        let result = await CLIRunner(executable: "/bin/ps").run(["-axo", "pid=,ppid=,rss=,%cpu=,comm="], timeout: 5)
        guard result.succeeded else { return [] }
        return parseProcesses(result.standardOutput, root: ProcessInfo.processInfo.processIdentifier)
    }

    /// 解析 ps 输出并保留 root 及其后代。
    static func parseProcesses(_ text: String, root: Int32) -> [ProcessRow] {
        struct Raw { var pid: Int32; var ppid: Int32; var rss: Double; var cpu: Double; var name: String }
        var all: [Raw] = []
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
            guard parts.count == 5, let pid = Int32(parts[0]), let ppid = Int32(parts[1]), let rss = Double(parts[2]), let cpu = Double(parts[3]) else { continue }
            all.append(Raw(pid: pid, ppid: ppid, rss: rss, cpu: cpu, name: URL(fileURLWithPath: String(parts[4])).lastPathComponent))
        }
        var included: Set<Int32> = [root]
        var changed = true
        while changed {
            changed = false
            for item in all where included.contains(item.ppid) && !included.contains(item.pid) { included.insert(item.pid); changed = true }
        }
        return all.filter { included.contains($0.pid) }.map { ProcessRow(id: $0.pid, name: $0.name, rssMB: $0.rss / 1024, cpu: $0.cpu) }.sorted { $0.id < $1.id }
    }

    private func runDoctor() async {
        doctorRunning = true
        defer { doctorRunning = false }
        let tools = await Toolchain.shared.resolve()
        guard let path = tools.claudePath else { doctorOutput = "没有找到 claude 命令行工具"; return }
        let result = await CLIRunner(executable: path, environment: tools.environment).run(["doctor"], in: center.paths.workspace, timeout: 60)
        let text = result.standardOutput + (result.standardError.isEmpty ? "" : "\n" + result.standardError)
        doctorOutput = text.isEmpty ? result.failureMessage : text
    }

    /// 生成诊断报告文本。
    func buildReport() async -> String {
        let tools = await Toolchain.shared.resolve()
        var lines = ["# OhMyAgent 诊断报告", "时间: \(Date().formatted(.iso8601))", "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)",
                     "应用版本: \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")",
                     "node: \(tools.nodePath ?? "-") \(tools.nodeVersion ?? "")", "claude: \(tools.claudePath ?? "-")", "adapter: \(tools.adapterEntry ?? "-")",
                     "首帧: \(DiagnosticsStore.shared.firstFrameMilliseconds.map { "\($0)ms" } ?? "-")", "", "## 进程"]
        lines += rows.map { String(format: "%@ (%d) %.0fMB cpu %.1f%%", $0.name, $0.id, $0.rssMB, $0.cpu) }
        let settings = ClaudeSettingsModel(paths: center.paths)
        lines += ["", "## settings.json env 键名", settings.dictionary(["env"]).keys.sorted().joined(separator: ", ")]
        if let doctorOutput { lines += ["", "## claude doctor", doctorOutput] }
        for model in SessionRegistry.shared.models {
            lines += ["", "## Agent 日志(\(model.agentName))"] + model.diagnostics
        }
        let text = lines.joined(separator: "\n")
        return redact ? DiagnosticsRedactor.redact(text) : text
    }

    private func export() async {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "OhMyAgent-diagnostics.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try await buildReport().write(to: url, atomically: true, encoding: .utf8)
            exportMessage = "已导出到 \(url.path)"
        } catch { exportMessage = "导出失败:\(error.localizedDescription)" }
    }
}

/// 诊断脱敏。
enum DiagnosticsRedactor {
    /// 替换用户目录并抹去常见令牌形态。
    static func redact(_ text: String) -> String {
        var result = text.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        for pattern in ["sk-[A-Za-z0-9_\\-]{8,}", "Bearer\\s+[A-Za-z0-9._\\-]{8,}"] {
            result = result.replacingOccurrences(of: pattern, with: "[已脱敏]", options: .regularExpression)
        }
        return result
    }
}
