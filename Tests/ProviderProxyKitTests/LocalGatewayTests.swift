// @author ixxxxoooo
// 本机网关测试:令牌分发、路径剥离、注销与未知路由。

import Foundation
import Testing
@testable import ProviderProxyKit

@Suite("本机网关")
struct LocalGatewayTests {
    @Test("路径拆分:令牌段与其余部分")
    func splitPath() {
        #expect(LocalGateway.split(path: "/abc/v1/messages").token == "abc")
        #expect(LocalGateway.split(path: "/abc/v1/messages").rest == "/v1/messages")
        #expect(LocalGateway.split(path: "/abc").rest == "/")
        #expect(LocalGateway.split(path: "/abc?x=1").rest == "/?x=1")
        #expect(LocalGateway.split(path: "/").token == nil)
    }

    @Test("同一监听按令牌分发,处理器看到的路径已去掉令牌;注销后 404")
    func dispatchByToken() async throws {
        let gateway = LocalGateway()
        let first = try await gateway.register { request in
            .full(status: 200, headers: [:], body: Data("A:\(request.path)".utf8))
        }
        let second = try await gateway.register { request in
            .full(status: 200, headers: [:], body: Data("B:\(request.path)".utf8))
        }
        #expect(first.token != second.token)
        #expect(first.url.port == second.url.port, "共用同一个回环端口")

        func get(_ base: URL, _ path: String) async throws -> (String, Int) {
            let (data, response) = try await URLSession(configuration: .ephemeral).data(from: base.appendingPathComponent(path))
            return (String(decoding: data, as: UTF8.self), (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        #expect(try await get(first.url, "v1/x").0 == "A:/v1/x")
        #expect(try await get(second.url, "v1/y").0 == "B:/v1/y")

        await gateway.unregister(token: first.token)
        #expect(try await get(first.url, "v1/x").1 == 404)
        #expect(try await get(second.url, "v1/y").1 == 200)
        await gateway.shutdown()
        #expect(await gateway.currentPort == nil)
    }

    @Test("非法令牌被拒绝")
    func rejectsBadToken() async {
        let gateway = LocalGateway()
        await #expect(throws: LoopbackServerError.self) {
            _ = try await gateway.register(token: "a/b") { _ in .full(status: 200, headers: [:], body: Data()) }
        }
        await gateway.shutdown()
    }
}
