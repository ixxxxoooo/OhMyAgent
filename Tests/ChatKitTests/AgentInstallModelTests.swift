// @author ixxxxoooo
// AgentInstallModel:注册表刷新回退、安装后登记、默认模型写入、卸载清理、失败状态。均使用临时目录与桩下载器,不联网。

import AgentHost
import Foundation
import Testing

@testable import ChatKit

private struct ZipDownloader: ArchiveDownloading {
    let zip: URL?
    func download(from url: URL, to destination: URL, progress: @escaping @Sendable (Double?) -> Void) async throws {
        guard let zip else { throw URLError(.notConnectedToInternet) }
        try FileManager.default.copyItem(at: zip, to: destination)
    }
}

@MainActor
@Suite("Agent 一键安装模型", .serialized)
struct AgentInstallModelTests {
    private func temp() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("agent-model-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 打一个含可执行脚本且不可压缩填充的 zip。
    private func makeZip(in dir: URL) throws -> URL {
        let payload = dir.appendingPathComponent("payload")
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
        try "#!/bin/sh\necho ok\n".write(to: payload.appendingPathComponent("agy_acp_server.par"), atomically: true, encoding: .utf8)
        try Data((0..<4096).map { _ in UInt8.random(in: 0...255) }).write(to: payload.appendingPathComponent("pad.bin"))
        let zip = dir.appendingPathComponent("a.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", payload.path, zip.path]
        try process.run()
        process.waitUntilExit()
        return zip
    }

    private func makeModel(root: URL, zip: URL?, fetch: @escaping @Sendable () async throws -> [RegistryAgent]) -> (AgentInstallModel, AgentRegistryModel) {
        let registry = AgentRegistryModel(store: AgentRegistryStore(url: root.appendingPathComponent("agents.json")))
        let installer = AgentInstaller(root: root.appendingPathComponent("agents"), downloader: ZipDownloader(zip: zip))
        return (AgentInstallModel(installer: installer, registry: registry, fetchRegistry: fetch), registry)
    }

    /// 轮询等待条件成立(最多约 5 秒)。
    private func wait(_ condition: () -> Bool) async {
        for _ in 0..<100 where !condition() { try? await Task.sleep(for: .milliseconds(50)) }
    }

    @Test("注册表不可达时静默使用内置条目;可达时采用最新条目")
    func refreshFallback() async throws {
        let root = try temp()
        defer { try? FileManager.default.removeItem(at: root) }
        let (offline, _) = makeModel(root: root, zip: nil) { throw URLError(.notConnectedToInternet) }
        offline.refresh()
        await wait { offline.phase == .idle }
        #expect(offline.latest.version == RegistryAgent.antigravityFallback.version)

        var newer = RegistryAgent.antigravityFallback
        newer.version = "9.9.9"
        let (online, _) = makeModel(root: root, zip: nil) { [newer] in [newer] }
        online.refresh()
        await wait { online.latest.version == "9.9.9" }
        #expect(online.latest.version == "9.9.9")
    }

    @Test("安装成功后登记 Agent、可写入默认模型,卸载后移除登记")
    func installRegisterUninstall() async throws {
        let root = try temp()
        defer { try? FileManager.default.removeItem(at: root) }
        let zip = try makeZip(in: root)
        let (model, registry) = makeModel(root: root, zip: zip) { [] }
        // 当前平台的发行包指向本地桩下载器(域名仍须在白名单内)
        #expect(model.installed == nil && !model.isRegistered)
        model.install()
        await wait { model.installed != nil }
        #expect(model.installed != nil)
        #expect(model.isRegistered)
        let descriptor = try #require(registry.data.allAgents.first { $0.id == "antigravity" })
        #expect(descriptor.registryId == "antigravity-acp" && descriptor.command == nil)

        model.setDefaultModel("  gemini-3-pro  ")
        #expect(model.defaultModel == "gemini-3-pro")
        model.setDefaultModel("")
        #expect(model.defaultModel.isEmpty)

        model.uninstall()
        #expect(model.installed == nil && !model.isRegistered)
    }

    @Test("下载失败进入失败状态且不登记")
    func installFailure() async throws {
        let root = try temp()
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, _) = makeModel(root: root, zip: nil) { [] }
        model.install()
        await wait { if case .failed = model.phase { true } else { false } }
        if case .failed = model.phase {} else { Issue.record("应进入失败状态") }
        #expect(model.installed == nil && !model.isRegistered)
    }

    @Test("描述符兼容:旧 agents.json 无 registryId 字段仍可解码,新字段往返保持")
    func descriptorCompat() throws {
        let legacy = Data(#"{"id":"x","name":"X","kind":"genericACP","command":"x","args":[],"env":{},"enabled":true}"#.utf8)
        let old = try JSONDecoder().decode(AgentDescriptor.self, from: legacy)
        #expect(old.registryId == nil)
        let data = try JSONEncoder().encode(AgentDescriptor.antigravity)
        let back = try JSONDecoder().decode(AgentDescriptor.self, from: data)
        #expect(back.registryId == "antigravity-acp")
    }
}
