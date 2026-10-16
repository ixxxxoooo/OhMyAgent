// @author ixxxxoooo
// 演示模式隔离层测试:启用判断、路径解析、隔离位置均落在沙盒内,不触碰真实数据目录。

import Foundation
import Testing
@testable import DemoKit

@Suite("演示模式隔离层")
struct DemoEnvironmentTests {
    @Test("仅 OMA_DEMO=1 启用演示模式")
    func enabled() {
        #expect(DemoEnvironment.isEnabled(environment: ["OMA_DEMO": "1"]))
        #expect(!DemoEnvironment.isEnabled(environment: ["OMA_DEMO": "0"]))
        #expect(!DemoEnvironment.isEnabled(environment: [:]))
        #expect(DemoEnvironment.current(environment: [:]) == nil)
    }

    @Test("解析重置与自动场景参数")
    func parsesOptions() throws {
        let env = try #require(DemoEnvironment.current(environment: [
            "OMA_DEMO": "1", "OMA_DEMO_ROOT": "/tmp/oma-demo-env", "OMA_DEMO_RESET": "1", "OMA_DEMO_SCENARIO": "tools-files",
        ]))
        #expect(env.reset)
        #expect(env.scenario == "tools-files")
        #expect(env.paths.root.path == "/tmp/oma-demo-env")
        let plain = try #require(DemoEnvironment.current(environment: ["OMA_DEMO": "1", "OMA_DEMO_ROOT": "/tmp/oma-demo-env", "OMA_DEMO_SCENARIO": ""]))
        #expect(!plain.reset)
        #expect(plain.scenario == nil)
    }

    @Test("隔离位置全部在沙盒内,且不等于真实路径")
    func isolatedLocations() throws {
        let root = "/tmp/oma-demo-iso"
        let env = DemoEnvironment(paths: DemoPaths(root: URL(fileURLWithPath: root)))
        for url in [env.workbenchStoreURL, env.homeDirectory, env.providerDirectory] {
            #expect(url.path.hasPrefix(root + "/"))
        }
        let realSupport = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/OhMyAgent").path
        #expect(env.workbenchStoreURL.path != realSupport + "/workbench.json")
        #expect(env.providerDirectory.path != realSupport)
        #expect(DemoEnvironment.defaultsSuiteName != Bundle.main.bundleIdentifier)
    }

    @Test("prepare 生成项目并创建提供商目录;reset 清空演示 suite")
    func prepare() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oma-demo-prep-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let env = DemoEnvironment(paths: DemoPaths(root: root), reset: true)
        env.defaults.set("x", forKey: "probe")
        let infos = try await env.prepare()
        #expect(infos.count == DemoWorkspace.catalog.count)
        #expect(FileManager.default.fileExists(atPath: env.providerDirectory.path))
        #expect(env.defaults.string(forKey: "probe") == nil)
    }
}
