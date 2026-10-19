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

    @Test("更新方式原始值稳定")
    func modes() {
        #expect(UpdateMode(rawValue: "auto") == .auto)
        #expect(UpdateMode(rawValue: "x") == nil)
    }
}
