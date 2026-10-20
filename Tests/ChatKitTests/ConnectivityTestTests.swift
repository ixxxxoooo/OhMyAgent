// @author ixxxxoooo
import Foundation
import Testing
@testable import ChatKit

private actor Collector {
    var results: [String: ConnectivityResult] = [:]
    func set(_ id: String, _ value: ConnectivityResult) { results[id] = value }
}

@Suite("连通性测试")
struct ConnectivityTestTests {
    @Test("成功记录耗时,失败记录原因,互不影响")
    func mixedResults() async {
        let collector = Collector()
        let targets = [
            ConnectivityTarget(name: "A", host: "a.test", icon: "globe"),
            ConnectivityTarget(name: "B", host: "b.test", icon: "globe"),
        ]
        await ConnectivityTest.run(targets, probe: { host in
            if host == "b.test" { throw URLError(.timedOut) }
            return 42
        }, onResult: { id, result in await collector.set(id, result) })
        let results = await collector.results
        #expect(results["a.test"] == .reachable(milliseconds: 42))
        if case .failed = results["b.test"] {} else { Issue.record("b.test 应为失败") }
    }

    @Test("默认站点主机名唯一")
    func defaultsUnique() {
        let hosts = ConnectivityTarget.defaults.map(\.host)
        #expect(Set(hosts).count == hosts.count)
        #expect(hosts.count == 5)
    }
}
