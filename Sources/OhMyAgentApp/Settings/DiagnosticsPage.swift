// @author ixxxxoooo
// 设置页:诊断(进程资源、启动耗时、claude doctor、脱敏导出)。

import AgentHost
import AppKit
import ChatKit
import ClaudeConfigKit
import DesignSystem
import OMLog
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
    @AppStorage(LogSystem.DefaultsKey.level) private var logLevel = "info"
    @AppStorage(LogSystem.DefaultsKey.traffic) private var logTraffic = false
    @AppStorage(LogSystem.DefaultsKey.hideHome) private var logHideHome = false
    @State private var showLogViewer = false

    var body: some View {
        SettingsForm {
            Section("启动耗时") {
                LabeledContent("启动到首帧", value: DiagnosticsStore.shared.firstFrameMilliseconds.map { "\($0) ms" } ?? String(localized: "未记录"))
                if let model = AppEnvironment.shared.sessionModels.first {
                    LabeledContent("Agent 连接", value: model.connectDuration.map { "\($0.components.seconds * 1000 + $0.components.attoseconds / 1_000_000_000_000_000) ms" } ?? String(localized: "未连接"))
                }
            }
            Section("进程资源") {
                ForEach(rows) { row in
                    LabeledContent("\(row.name) (\(row.id))") { Text(String(format: "%.0f MB · CPU %.1f%%", row.rssMB, row.cpu)).monospacedDigit() }
                }
                if rows.isEmpty { Text("正在读取…").foregroundStyle(OMColors.secondaryText) }
            }
            Section("日志") {
                Picker("日志级别", selection: $logLevel) {
                    Text("Debug(最详细)").tag("debug")
                    Text("Info(默认)").tag("info")
                    Text("Warning").tag("warning")
                    Text("Error").tag("error")
                }
                .onChange(of: logLevel) { _, value in
                    if let level = LogLevel(text: value) { LogSystem.shared.level = level; Log.log.info("日志级别已调整", ["level": value]) }
                }
                Toggle("记录 ACP 协议流量(acp-traffic 日志,载荷已脱敏并截断)", isOn: $logTraffic)
                    .onChange(of: logTraffic) { _, value in LogSystem.shared.trafficEnabled = value; Log.log.info("协议流量日志", ["enabled": "\(value)"]) }
                Toggle("日志中把家目录显示为 ~", isOn: $logHideHome)
                    .onChange(of: logHideHome) { _, value in LogSystem.shared.hideHome = value }
                HStack {
                    Button("查看日志…") { showLogViewer = true }
                    Button("打开日志目录") {
                        if let dir = LogSystem.shared.directory { NSWorkspace.shared.open(dir) }
                    }
                }
                Note("日志文件位于 ~/Library/Logs/OhMyAgent/(单文件 10MB 轮转,保留 7 天)。令牌、API Key 与授权头在写入前自动脱敏。排查问题时把 oma-日期.log 发给开发者即可。")
            }
            Section("claude doctor") {
                HStack {
                    Button("运行检查") { Task { await runDoctor() } }.disabled(doctorRunning || !center.canRunCLI)
                    if doctorRunning { OMSpinner(.small) }
                }
                if let doctorOutput {
                    ScrollView { Text(doctorOutput).font(OMFonts.monoSmall).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                        .frame(maxHeight: 180)
                }
            }
            Section("导出") {
                HStack {
                    Button("导出诊断包…") { Task { await export() } }
                    Text(redact ? String(localized: "已启用脱敏") : String(localized: "未脱敏")).font(OMFonts.small).foregroundStyle(OMColors.secondaryText)
                }
                if let exportMessage { Note(exportMessage) }
                Note("诊断包包含版本、工具路径、配置概要(仅键名)、最近 Agent 日志与计时,不含对话内容与凭据。")
            }
        }
        .task { await pollProcesses() }
        .sheet(isPresented: $showLogViewer) {
            VStack(spacing: 0) {
                HStack { Text("日志").font(OMFonts.title); Spacer(); Button("关闭") { showLogViewer = false }.keyboardShortcut(.cancelAction) }.padding(10)
                Divider()
                LogViewerView()
            }
            .frame(minWidth: 860, minHeight: 520)
        }
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
        guard let path = tools.claudePath else { doctorOutput = String(localized: "没有找到 claude 命令行工具"); return }
        let result = await CLIRunner(executable: path, environment: tools.environment).run(["doctor"], in: center.paths.workspace, timeout: 60)
        let text = result.standardOutput + (result.standardError.isEmpty ? "" : "\n" + result.standardError)
        doctorOutput = text.isEmpty ? result.failureMessage : text
    }

    /// 生成诊断报告文本。
    func buildReport() async -> String {
        let tools = await Toolchain.shared.resolve()
        var lines = [String(localized: "# OhMyAgent 诊断报告"), String(localized: "时间: \(Date().formatted(.iso8601))"), "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)",
                     String(localized: "应用版本: \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")"),
                     "node: \(tools.nodePath ?? "-") \(tools.nodeVersion ?? "")", "claude: \(tools.claudePath ?? "-")", "adapter: \(tools.adapterEntry ?? "-")",
                     String(localized: "首帧: \(DiagnosticsStore.shared.firstFrameMilliseconds.map { "\($0)ms" } ?? "-")"), "", String(localized: "## 进程")]
        lines += rows.map { String(format: "%@ (%d) %.0fMB cpu %.1f%%", $0.name, $0.id, $0.rssMB, $0.cpu) }
        let settings = ClaudeSettingsModel(paths: center.paths)
        lines += ["", String(localized: "## settings.json env 键名"), settings.dictionary(["env"]).keys.sorted().joined(separator: ", ")]
        if let doctorOutput { lines += ["", "## claude doctor", doctorOutput] }
        for model in AppEnvironment.shared.sessionModels {
            lines += ["", String(localized: "## Agent 日志(\(model.agentName))")] + model.diagnostics
        }
        lines += ["", String(localized: "## 最近应用日志(最多 500 条)")] + LogSystem.shared.recent(limit: 500).map(\.line)
        let text = lines.joined(separator: "\n")
        return redact ? DiagnosticsRedactor.redact(text) : text
    }

    private func export() async {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "OhMyAgent-diagnostics.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try await buildReport().write(to: url, atomically: true, encoding: .utf8)
            exportMessage = String(localized: "已导出到 \(url.path)")
        } catch { exportMessage = String(localized: "导出失败:\(error.localizedDescription)") }
    }
}

/// 诊断脱敏。
enum DiagnosticsRedactor {
    /// 替换用户目录并抹去常见令牌形态。
    static func redact(_ text: String) -> String {
        LogRedactor.redact(text, hideHome: true)
    }
}
