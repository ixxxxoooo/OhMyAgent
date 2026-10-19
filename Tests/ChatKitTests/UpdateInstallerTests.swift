// @author ixxxxoooo
import Foundation
import Testing
@testable import ChatKit

@Suite("更新安装器")
struct UpdateInstallerTests {
    @Test("最佳安装时间:需要空闲足够久且无忙碌会话")
    func installTiming() {
        #expect(UpdateTiming.canInstallNow(idleSeconds: 1000, busySessions: 0))
        #expect(!UpdateTiming.canInstallNow(idleSeconds: 1000, busySessions: 1))
        #expect(!UpdateTiming.canInstallNow(idleSeconds: 60, busySessions: 0))
    }

    @Test("计费或受限网络不自动下载")
    func downloadTiming() {
        #expect(UpdateTiming.canDownloadNow(isExpensive: false, isConstrained: false))
        #expect(!UpdateTiming.canDownloadNow(isExpensive: true, isConstrained: false))
        #expect(!UpdateTiming.canDownloadNow(isExpensive: false, isConstrained: true))
    }

    @Test("sha256 与已知值一致")
    func sha() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("oma-update-sha-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("abc".utf8).write(to: file)
        #expect(try UpdateInstaller.sha256(of: file) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test("更新地址:正式版只允许 https,本机回环与 file 仅开发版放行")
    func sourcePolicy() throws {
        let https = try #require(URL(string: "https://github.com/a/b/releases/latest/download/appcast.json"))
        let loopback = try #require(URL(string: "http://127.0.0.1:8000/appcast.json"))
        let file = URL(fileURLWithPath: "/tmp/appcast.json")
        let plain = try #require(URL(string: "http://example.com/appcast.json"))
        #expect(UpdateChecker.isAllowedSource(https, allowLocal: false))
        #expect(!UpdateChecker.isAllowedSource(loopback, allowLocal: false))
        #expect(!UpdateChecker.isAllowedSource(file, allowLocal: false))
        #expect(UpdateChecker.isAllowedSource(loopback, allowLocal: true))
        #expect(UpdateChecker.isAllowedSource(file, allowLocal: true))
        #expect(!UpdateChecker.isAllowedSource(plain, allowLocal: true))
    }

    /// 用一个已退出进程的 PID 运行替换脚本。
    private func runReplaceScript(target: String, staged: String, root: String) throws {
        let done = Process()
        done.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try done.run()
        done.waitUntilExit()
        let script = URL(fileURLWithPath: root).deletingLastPathComponent().appendingPathComponent("replace-\(UUID().uuidString).sh")
        try UpdateInstaller.replaceScript.write(to: script, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path, "\(done.processIdentifier)", target, staged, root, "0"]
        try process.run()
        process.waitUntilExit()
    }

    @Test("替换脚本:路径含引号与 $ 也能替换成功,并清理备份与暂存")
    func replaceScriptWithSpecialPaths() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("oma-update-replace-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: base) }
        let target = base.appendingPathComponent("Apps \"q\" $HOME `x`/OhMyAgent.app")
        let root = base.appendingPathComponent("updates")
        let staged = root.appendingPathComponent("1.0.2/OhMyAgent.app")
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        try fm.createDirectory(at: staged, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: target.appendingPathComponent("v"))
        try Data("new".utf8).write(to: staged.appendingPathComponent("v"))
        try runReplaceScript(target: target.path, staged: staged.path, root: root.path)
        #expect(try String(contentsOf: target.appendingPathComponent("v"), encoding: .utf8) == "new")
        #expect(!fm.fileExists(atPath: target.path + ".old"))
        #expect(!fm.fileExists(atPath: root.path))
    }

    @Test("替换脚本:无法移动原应用时写下失败标记并保留暂存")
    func replaceScriptFailureMarker() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("oma-update-replace-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: base) }
        let root = base.appendingPathComponent("updates")
        let staged = root.appendingPathComponent("1.0.2/OhMyAgent.app")
        try fm.createDirectory(at: staged, withIntermediateDirectories: true)
        try runReplaceScript(target: base.appendingPathComponent("missing/OhMyAgent.app").path, staged: staged.path, root: root.path)
        let marker = root.appendingPathComponent(UpdateInstaller.failureMarkerName)
        #expect(try String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) == "move")
        #expect(fm.fileExists(atPath: staged.path))
    }

    @Test("更新方式原始值稳定")
    func modes() {
        #expect(UpdateMode(rawValue: "auto") == .auto)
        #expect(UpdateMode(rawValue: "x") == nil)
    }
}

@Suite("更新说明")
struct WhatsNewTests {
    @Test("更新后展示一次,未追上版本时保留")
    func pending() {
        let defaults = UserDefaults(suiteName: "oma-whatsnew-\(UUID().uuidString)")!
        WhatsNew.remember(version: "1.1.0", notes: "a;b", defaults: defaults)
        #expect(WhatsNew.takePending(currentVersion: "1.0.0", defaults: defaults) == nil)
        #expect(WhatsNew.takePending(currentVersion: "1.1.0", defaults: defaults)?.notes == "a;b")
        #expect(WhatsNew.takePending(currentVersion: "1.1.0", defaults: defaults) == nil)
    }

    @Test("说明整理为项目符号并限制条数")
    func bullets() {
        #expect(WhatsNew.bulletList("a; b;;c") == "• a\n• b\n• c")
        #expect(WhatsNew.bulletList("1;2;3", limit: 2) == "• 1\n• 2\n…")
        #expect(WhatsNew.bulletList(nil) == "")
    }
}
