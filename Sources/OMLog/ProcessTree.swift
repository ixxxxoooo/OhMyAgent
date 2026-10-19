// @author ixxxxoooo
// 进程树探针:用 libproc 列出某进程的全部后代,判断 Agent 进程下是否还挂着 shell 命令(后台任务)。

import Darwin
import Foundation

/// 进程树工具(无状态)。
public enum ProcessTree {
    /// 视为「命令」的 shell 进程名。后台 Bash 任务由这些 shell 启动;MCP 服务器等常驻子进程通常直接是 node/python,不在其内。
    static let shellNames: Set<String> = ["bash", "zsh", "sh", "dash", "fish"]

    /// 列出直接子进程。
    /// - Parameter pid: 父进程号
    /// - Returns: 子进程号;pid 非法或读取失败为空
    static func children(of pid: Int32) -> [Int32] {
        guard pid > 0 else { return [] }
        // 注意:libproc 的 proc_listchildpids 返回的是进程个数(不是字节数)
        var buffer = [Int32](repeating: 0, count: 1024)
        let count = proc_listchildpids(pid, &buffer, Int32(buffer.count * MemoryLayout<Int32>.size))
        guard count > 0 else { return [] }
        return buffer.prefix(min(Int(count), buffer.count)).filter { $0 > 0 }
    }

    /// 进程名(可执行文件名)。
    /// - Parameter pid: 进程号
    /// - Returns: 名称;读取失败为 nil
    static func name(of pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    /// 全部后代进程号(广度优先,最多 512 个防止异常树)。
    /// - Parameter pid: 根进程号
    /// - Returns: 后代进程号
    public static func descendants(of pid: Int32) -> [Int32] {
        var result: [Int32] = []
        var queue = children(of: pid)
        while !queue.isEmpty, result.count < 512 {
            let next = queue.removeFirst()
            result.append(next)
            queue.append(contentsOf: children(of: next))
        }
        return result
    }

    /// 根进程下是否还有 shell 后代(即仍在运行的后台命令)。
    /// - Parameter pid: 根进程号(Agent 进程)
    /// - Returns: 有则 true
    public static func hasShellDescendant(of pid: Int32) -> Bool {
        descendants(of: pid).contains { child in name(of: child).map { shellNames.contains($0) } ?? false }
    }
}
