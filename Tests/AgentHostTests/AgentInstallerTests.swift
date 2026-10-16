// @author ixxxxoooo
// Agent 一键安装:注册表解析、域名白名单、解压/权限/原子安装/卸载、异常包拒绝。

import Foundation
import Testing

@testable import AgentHost

/// 测试下载器:不联网,把预先打好的 zip 复制到目标位置。
private struct StubDownloader: ArchiveDownloading {
    let zip: URL?
    var fail: Bool = false

    func download(from url: URL, to destination: URL, progress: @escaping @Sendable (Double?) -> Void) async throws {
        if fail { throw URLError(.notConnectedToInternet) }
        progress(0.5)
        if let zip { try FileManager.default.copyItem(at: zip, to: destination) } else { try Data("x".utf8).write(to: destination) }
        progress(1)
    }
}

@Suite("Agent 一键安装", .serialized)
struct AgentInstallerTests {
    private func temp() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("agent-install-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 用 ditto 打一个含可执行脚本(且体积超过 1KB)的 zip。
    private func makeZip(in dir: URL, command: String = "agy_acp_server.par", extra: (URL) throws -> Void = { _ in }) throws -> URL {
        let payload = dir.appendingPathComponent("payload")
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
        try "#!/bin/sh\necho ok\n".write(to: payload.appendingPathComponent(command), atomically: true, encoding: .utf8)
        // 随机填充:不可压缩,保证压缩包超过「过小」阈值
        try Data((0..<4096).map { _ in UInt8.random(in: 0...255) }).write(to: payload.appendingPathComponent("pad.bin"))
        try extra(payload)
        let zip = dir.appendingPathComponent("a.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", payload.path, zip.path]
        try process.run()
        process.waitUntilExit()
        return zip
    }

    private func agent(cmd: String = "./agy_acp_server.par", archive: String = "https://dl.google.com/agy-extensions/releases/macos/x.zip") -> RegistryAgent {
        RegistryAgent(id: "antigravity-acp", name: "Google Antigravity", version: "1.4.0", binary: ["darwin-aarch64": RegistryBinary(archive: archive, cmd: cmd, args: ["--flag"])])
    }

    @Test("注册表解析:读取二进制分发,忽略缺字段的平台,保留无二进制分发的条目")
    func parseRegistry() throws {
        let json = """
        {"version":"1","agents":[
          {"id":"antigravity-acp","name":"Google Antigravity","version":"1.4.0","description":"d",
           "distribution":{"binary":{"darwin-aarch64":{"archive":"https://dl.google.com/a.zip","cmd":"./agy_acp_server.par"},"bad":{"cmd":"x"}}}},
          {"id":"npx-agent","name":"N","version":"1","distribution":{"npx":{"package":"p"}}}
        ],"extensions":[]}
        """
        let agents = try ACPRegistry.parse(Data(json.utf8))
        #expect(agents.count == 2)
        let agy = try #require(agents.first)
        #expect(agy.binary.keys.sorted() == ["darwin-aarch64"] && agy.binary["darwin-aarch64"]?.cmd == "./agy_acp_server.par")
        #expect(agents[1].binary.isEmpty)
        #expect(RegistryAgent.antigravityFallback.binary[ACPRegistry.currentPlatform] != nil)
    }

    @Test("域名白名单:只接受 HTTPS + dl.google.com,拒绝其他主机、http 与带用户信息的地址")
    func hostAllowlist() throws {
        let installer = AgentInstaller(root: try temp(), downloader: StubDownloader(zip: nil))
        _ = try installer.validate(archive: "https://dl.google.com/x.zip")
        #expect(throws: AgentInstallError.untrustedSource("evil.com")) { try installer.validate(archive: "https://evil.com/x.zip") }
        #expect(throws: AgentInstallError.self) { try installer.validate(archive: "http://dl.google.com/x.zip") }
        #expect(throws: AgentInstallError.self) { try installer.validate(archive: "https://user@dl.google.com/x.zip") }
        #expect(throws: AgentInstallError.self) { try installer.validate(archive: "https://dl.google.com.evil.com/x.zip") }
    }

    @Test("安装:解压、设可执行权限、写清单、清理暂存;卸载后清空")
    func installAndUninstall() async throws {
        let dir = try temp(), root = try temp()
        defer { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: root) }
        let installer = AgentInstaller(root: root, downloader: StubDownloader(zip: try makeZip(in: dir)))
        let installed = try await installer.install(agent(), platform: "darwin-aarch64")
        #expect(installed.version == "1.4.0" && installed.args == ["--flag"])
        #expect(installed.executable.hasSuffix("antigravity-acp/1.4.0/agy_acp_server.par"))
        #expect(FileManager.default.isExecutableFile(atPath: installed.executable))
        #expect(installer.installed(id: "antigravity-acp")?.executable == installed.executable)
        // 暂存目录已清理
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".staging") }
        #expect(leftovers.isEmpty)
        try installer.uninstall(id: "antigravity-acp")
        #expect(installer.installed(id: "antigravity-acp") == nil)
    }

    @Test("升级:新版本安装后旧版本目录被清理,needsUpdate 反映版本差异")
    func upgrade() async throws {
        let dir = try temp(), root = try temp()
        defer { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: root) }
        let installer = AgentInstaller(root: root, downloader: StubDownloader(zip: try makeZip(in: dir)))
        let old = try await installer.install(agent(), platform: "darwin-aarch64")
        var next = agent()
        next.version = "1.5.0"
        #expect(AgentInstaller.needsUpdate(installed: old, latest: next))
        let upgraded = try await installer.install(next, platform: "darwin-aarch64")
        #expect(upgraded.version == "1.5.0")
        let versions = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("antigravity-acp").path).sorted()
        #expect(versions == ["1.5.0", "manifest.json"])
    }

    @Test("拒绝:不支持的平台、可执行路径越界、缺少可执行文件、过小的压缩包、下载失败、危险的标识")
    func rejections() async throws {
        let dir = try temp(), root = try temp()
        defer { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: root) }
        let good = StubDownloader(zip: try makeZip(in: dir))
        let installer = AgentInstaller(root: root, downloader: good)
        await #expect(throws: AgentInstallError.unsupportedPlatform("linux-x86_64")) { try await installer.install(agent(), platform: "linux-x86_64") }
        await #expect(throws: AgentInstallError.missingExecutable("../../escape")) { try await installer.install(agent(cmd: "../../escape"), platform: "darwin-aarch64") }
        await #expect(throws: AgentInstallError.missingExecutable("./nope")) { try await installer.install(agent(cmd: "./nope"), platform: "darwin-aarch64") }
        await #expect(throws: AgentInstallError.corruptArchive) { try await AgentInstaller(root: root, downloader: StubDownloader(zip: nil)).install(agent(), platform: "darwin-aarch64") }
        await #expect(throws: AgentInstallError.self) { try await AgentInstaller(root: root, downloader: StubDownloader(zip: nil, fail: true)).install(agent(), platform: "darwin-aarch64") }
        var evil = agent()
        evil.id = "../evil"
        await #expect(throws: AgentInstallError.invalidIdentifier("../evil")) { try await installer.install(evil, platform: "darwin-aarch64") }
        #expect(installer.installed(id: "../evil") == nil)
    }

    @Test("越界符号链接的压缩包被拒绝")
    func unsafeSymlink() async throws {
        let dir = try temp(), root = try temp()
        defer { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: root) }
        let zip = try makeZip(in: dir) { payload in
            try FileManager.default.createSymbolicLink(at: payload.appendingPathComponent("link"), withDestinationURL: URL(fileURLWithPath: "/etc"))
        }
        let installer = AgentInstaller(root: root, downloader: StubDownloader(zip: zip))
        await #expect(throws: AgentInstallError.unsafeArchive) { try await installer.install(agent(), platform: "darwin-aarch64") }
        #expect(installer.installed(id: "antigravity-acp") == nil)
    }
}
