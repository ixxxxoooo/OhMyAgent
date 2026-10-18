// @author ixxxxoooo
// 浏览器日志落盘与网络请求呈现:日志超过内联上限时写到缓存目录,只把行数、最近预览与路径交给 Agent(对齐 Cursor)。

import ChatKit
import Foundation
import OMLog

/// 浏览器日志文件。
enum BrowserLogFiles {
    /// 日志目录(应用缓存目录下,系统可随时清理)。
    static var directory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppEnv.folderName, isDirectory: true)
            .appendingPathComponent("browser-logs", isDirectory: true)
    }

    /// 呈现日志:行数不多直接返回;太多则写文件并返回预览与路径。
    /// - Parameters:
    ///   - lines: 全部日志行
    ///   - kind: 日志类别(文件名前缀)
    ///   - tabID: 浏览器标签 id
    ///   - noun: 日志名称(给模型看)
    ///   - empty: 空日志文案
    static func render(lines: [String], kind: String, tabID: String, noun: String, empty: String) -> String {
        var path: String?
        if BrowserLogFormat.needsFile(lines.count) {
            let url = directory.appendingPathComponent("\(tabID)-\(kind).log")
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
                path = url.path
            } catch {
                Log.app.warning("写浏览器日志文件失败", ["kind": kind, "error": error.localizedDescription])
            }
        }
        return BrowserLogFormat.render(lines: lines, noun: noun, empty: empty, filePath: path)
    }
}

extension BrowserTabModel {
    /// 网络请求列表(带序号)或某个请求的详情。
    /// - Parameter request: 序号(1 起);nil 为列表
    func describeNetwork(request: Int?) -> String {
        let all = network
        if let request {
            guard request >= 1, request <= all.count else { return "No request #\(request); the list has \(all.count) request(s)." }
            let line = all[request - 1]
            var text = "#\(request) \(line.method) \(line.url)\nStatus: \(line.error ?? String(line.status)) (\(line.milliseconds) ms)"
            if let type = line.contentType, !type.isEmpty { text += "\nContent-Type: \(type)" }
            text += "\nRequest body: " + (line.requestBody.map { BrowserLogFormat.clip($0, limit: 4000) } ?? "(none)")
            text += "\nResponse body: " + (line.responseBody.map { BrowserLogFormat.clip($0, limit: 4000) } ?? "(not captured — only text/JSON fetch/XHR responses are kept)")
            return text
        }
        let lines = all.enumerated().map { index, line in
            "#\(index + 1) \(line.method) \(line.url) → \(line.error ?? String(line.status)) (\(line.milliseconds) ms)" + (line.contentType.map { " [\($0)]" } ?? "")
        }
        return BrowserLogFiles.render(lines: lines, kind: "network", tabID: id, noun: "network requests", empty: "No network requests recorded.")
    }
}
