// @author ygw
// OhMyAgentBridge:stdio ↔ Unix socket 垫片。Agent 把它当作 stdio 类型的 MCP 服务器启动,
// 它把标准输入输出原样转发到 OhMyAgent 的 Bridge socket(环境变量 OMA_BRIDGE_SOCKET)。

import Darwin
import Foundation

guard let path = ProcessInfo.processInfo.environment["OMA_BRIDGE_SOCKET"], !path.isEmpty else {
    FileHandle.standardError.write(Data("缺少环境变量 OMA_BRIDGE_SOCKET\n".utf8))
    exit(2)
}

let fd = socket(AF_UNIX, SOCK_STREAM, 0)
var address = sockaddr_un()
address.sun_family = sa_family_t(AF_UNIX)
withUnsafeMutableBytes(of: &address.sun_path) { buffer in
    for (index, byte) in path.utf8.prefix(100).enumerated() { buffer[index] = byte }
}
let connected = withUnsafePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
}
guard fd >= 0, connected == 0 else {
    FileHandle.standardError.write(Data("无法连接 Bridge socket \(path):\(String(cString: strerror(errno)))\n".utf8))
    exit(1)
}

/// 把 source 读到的内容全部写入 target,直到 EOF。
func pump(from source: Int32, to target: Int32) {
    var buffer = [UInt8](repeating: 0, count: 16384)
    while true {
        let count = read(source, &buffer, buffer.count)
        if count <= 0 { return }
        var offset = 0
        while offset < count {
            // 注意:不能写 &buffer[offset],那只会传出单个元素的临时副本
            let written = buffer.withUnsafeBytes { write(target, $0.baseAddress!.advanced(by: offset), count - offset) }
            if written <= 0 { return }
            offset += written
        }
    }
}

let upstream = Thread { pump(from: STDIN_FILENO, to: fd); shutdown(fd, SHUT_WR) }
upstream.start()
pump(from: fd, to: STDOUT_FILENO)
exit(0)
