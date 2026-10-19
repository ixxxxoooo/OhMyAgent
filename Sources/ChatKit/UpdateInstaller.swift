// @author ixxxxoooo
// 更新安装器:下载 dmg → 校验 sha256 → 挂载并取出 app 暂存 → 退出后由脚本替换并重启。
// 纯 Foundation,不含界面;应用层的 `UpdateModel` 负责状态与时机。

import CryptoKit
import Foundation
import OMLog

/// 更新方式(设置页「更新方式」)。
public enum UpdateMode: String, Sendable, CaseIterable {
    /// 只提醒,点击后手动下载安装
    case remind
    /// 发现后在合适的网络下自动下载,由用户点击按钮重启更新
    case download
    /// 自动下载,并在最佳时间(电脑空闲、没有会话在运行,或下次退出时)自动安装
    case auto
}

/// 暂存好的更新(下载并校验完成)。
public struct StagedUpdate: Codable, Sendable, Equatable {
    public var version: String
    public var build: Int
    /// 暂存的 app 路径
    public var appPath: String
    /// 发布说明(旧版本暂存文件没有该字段)
    public var notes: String?
}

/// 更新时机判断(纯函数,便于测试)。
public enum UpdateTiming {
    /// 是否可以自动重启安装:电脑空闲足够久,且没有会话在运行或等待输入。
    /// - Parameters:
    ///   - idleSeconds: 距离上次键鼠操作的秒数
    ///   - busySessions: 运行中/等待输入的会话数
    ///   - minimumIdle: 所需最短空闲秒数(默认 15 分钟)
    /// - Returns: 可以安装为 true
    public static func canInstallNow(idleSeconds: TimeInterval, busySessions: Int, minimumIdle: TimeInterval = 900) -> Bool {
        busySessions == 0 && idleSeconds >= minimumIdle
    }

    /// 是否适合后台下载:昂贵(蜂窝/热点)或受限网络下不自动下载。
    /// - Parameters:
    ///   - isExpensive: 网络是否计费
    ///   - isConstrained: 是否开启了低数据模式
    /// - Returns: 适合下载为 true
    public static func canDownloadNow(isExpensive: Bool, isConstrained: Bool) -> Bool { !isExpensive && !isConstrained }
}

/// 安装错误。
public enum UpdateInstallError: Error, LocalizedError, Sendable {
    case badURL, checksumMissing, checksumMismatch, mountFailed(String), appMissing, signatureInvalid
    public var errorDescription: String? {
        switch self {
        case .badURL: return String(localized: "下载地址无效")
        case .checksumMissing: return String(localized: "发布源缺少安装包校验值(sha256),已拒绝安装")
        case .checksumMismatch: return String(localized: "安装包校验失败(sha256 不一致)")
        case .mountFailed(let m): return String(localized: "无法打开安装包:\(m)")
        case .appMissing: return String(localized: "安装包中没有应用")
        case .signatureInvalid: return String(localized: "安装包签名无效")
        }
    }
}

/// 更新安装器。
public enum UpdateInstaller {
    /// 暂存根目录(`Application Support/OhMyAgent[-Dev]/updates`)。
    public static var stagingRoot: URL { AppEnv.supportDirectory.appendingPathComponent("updates", isDirectory: true) }
    private static var readyFile: URL { stagingRoot.appendingPathComponent("ready.json") }
    /// 正式版的 Bundle ID:安装包签名的标识符必须与之一致(ad-hoc 签名没有团队 ID 可钉,至少钉住标识符)
    static let expectedIdentifier = "com.ixxxxoooo.OhMyAgent"

    /// 读取已暂存且比当前版本新的更新;过期的暂存会被清理。
    /// - Parameters:
    ///   - currentVersion: 当前短版本号
    ///   - currentBuild: 当前构建号
    /// - Returns: 可安装的暂存更新
    public static func loadStaged(currentVersion: String, currentBuild: Int) -> StagedUpdate? {
        guard let data = try? Data(contentsOf: readyFile), let staged = try? JSONDecoder().decode(StagedUpdate.self, from: data),
              FileManager.default.fileExists(atPath: staged.appPath) else { return nil }
        let order = UpdateChecker.compare(staged.version, currentVersion)
        guard order > 0 || (order == 0 && staged.build > currentBuild) else { clearStaged(); return nil }
        return staged
    }

    /// 清理全部暂存。
    public static func clearStaged() { try? FileManager.default.removeItem(at: stagingRoot) }

    /// 下载并校验、暂存更新。
    /// - Parameters:
    ///   - info: 版本信息(含 dmg 地址与 sha256)
    ///   - progress: 进度回调 0…1(任意线程)
    /// - Returns: 暂存结果
    public static func download(_ info: UpdateInfo, progress: @escaping @Sendable (Double) -> Void) async throws -> StagedUpdate {
        guard let url = URL(string: info.url), !url.isFileURL, UpdateChecker.isAllowedSource(url) else { throw UpdateInstallError.badURL }
        // 正式版必须带校验值;开发版的本地假发布源可以省略
        let expectedSHA = info.sha256?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if expectedSHA.isEmpty, !AppEnv.isDev() { throw UpdateInstallError.checksumMissing }
        let started = Date()
        let fm = FileManager.default
        clearStaged()
        let dir = stagingRoot.appendingPathComponent(info.version, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dmg = dir.appendingPathComponent("update.dmg")
        let observer = ProgressObserver(progress)
        let (tmp, _) = try await URLSession.shared.download(from: url, delegate: observer)
        try fm.moveItem(at: tmp, to: dmg)
        if !expectedSHA.isEmpty, try sha256(of: dmg) != expectedSHA {
            clearStaged(); throw UpdateInstallError.checksumMismatch
        }
        let app = try extractApp(from: dmg, into: dir)
        try? fm.removeItem(at: dmg)
        guard run("/usr/bin/codesign", ["--verify", "--deep", "--strict", "-R=identifier \"\(expectedIdentifier)\"", app.path]).status == 0 else {
            clearStaged(); throw UpdateInstallError.signatureInvalid
        }
        let staged = StagedUpdate(version: info.version, build: info.build ?? 0, appPath: app.path, notes: info.notes)
        try JSONEncoder().encode(staged).write(to: readyFile)
        Log.update.info("更新已下载并校验", ["version": info.version, "seconds": String(format: "%.1f", Date().timeIntervalSince(started))])
        return staged
    }

    /// 生成「等当前进程退出 → 替换 → 重启」的脚本并在后台启动。调用方随后应退出应用。
    /// - Parameters:
    ///   - staged: 暂存的更新
    ///   - targetApp: 要被替换的应用路径(通常是当前 bundle)
    ///   - relaunch: 替换后是否重新打开
    public static func launchReplacer(staged: StagedUpdate, targetApp: String, relaunch: Bool) throws {
        let script = stagingRoot.appendingPathComponent("replace.sh")
        try replaceScript.write(to: script, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path, "\(ProcessInfo.processInfo.processIdentifier)", targetApp, staged.appPath, stagingRoot.path, relaunch ? "1" : "0"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    /// 「等旧进程退出 → 替换 → 重启」脚本。路径一律作为位置参数传入,脚本里不拼接任何路径(路径含引号、$ 等字符也不会出错)。
    /// 等旧进程退出最多 60 秒,仍在运行说明退出被取消,放弃本次;替换失败时恢复原应用并写下失败标记,下次启动提示。
    /// 参数:$1 旧进程 PID、$2 要替换的应用、$3 暂存的新应用、$4 暂存根目录、$5 是否重新打开(1/0)。
    static var replaceScript: String {
        """
        #!/bin/sh
        # 参数:$1 旧进程 PID  $2 要替换的应用  $3 暂存的新应用  $4 暂存根目录  $5 是否重新打开(1/0)
        PID="$1"; TARGET="$2"; STAGED="$3"; ROOT="$4"; RELAUNCH="$5"
        LOG="$ROOT/\(replaceLogName)"
        i=0; while kill -0 "$PID" 2>/dev/null && [ $i -lt 120 ]; do sleep 0.5; i=$((i+1)); done
        if kill -0 "$PID" 2>/dev/null; then exit 0; fi
        BACKUP="$TARGET.old"
        rm -rf "$BACKUP"
        if mv "$TARGET" "$BACKUP" 2>>"$LOG"; then
          if /usr/bin/ditto "$STAGED" "$TARGET" 2>>"$LOG"; then
            /usr/bin/xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null
            rm -rf "$BACKUP" "$ROOT"
          else
            rm -rf "$TARGET"; mv "$BACKUP" "$TARGET"
            echo "copy" > "$ROOT/\(failureMarkerName)"
          fi
        else
          echo "move" > "$ROOT/\(failureMarkerName)"
        fi
        if [ "$RELAUNCH" = "1" ]; then /usr/bin/open "$TARGET"; fi
        """
    }

    /// 替换脚本失败时写下的标记文件名。
    static let failureMarkerName = "failed"
    /// 替换脚本的错误输出文件名。
    static let replaceLogName = "replace.log"

    /// 读取并清理上次安装失败的记录(替换脚本没能替换应用,常见原因是应用所在目录不可写)。
    /// 有记录时清空暂存,避免每次启动都显示「更新」、每次退出都重试失败。
    /// - Returns: 失败原因(含脚本错误输出摘要);上次没有失败为 nil
    public static func takeInstallFailure() -> String? {
        let marker = stagingRoot.appendingPathComponent(failureMarkerName)
        guard let step = try? String(contentsOf: marker, encoding: .utf8) else { return nil }
        let output = (try? String(contentsOf: stagingRoot.appendingPathComponent(replaceLogName), encoding: .utf8)) ?? ""
        clearStaged()
        let detail = String(output.suffix(400)).trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(step.trimmingCharacters(in: .whitespacesAndNewlines)): \(detail.isEmpty ? "-" : detail)"
    }

    // MARK: 内部

    /// 文件 sha256(小写十六进制)。
    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// 挂载 dmg,把其中的 .app 拷到暂存目录后卸载。
    private static func extractApp(from dmg: URL, into dir: URL) throws -> URL {
        let mount = dir.appendingPathComponent("mnt", isDirectory: true)
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        let attach = run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noverify", "-mountpoint", mount.path, dmg.path])
        guard attach.status == 0 else { throw UpdateInstallError.mountFailed(attach.output) }
        defer { _ = run("/usr/bin/hdiutil", ["detach", "-quiet", "-force", mount.path]); try? FileManager.default.removeItem(at: mount) }
        let apps = (try? FileManager.default.contentsOfDirectory(atPath: mount.path))?.filter { $0.hasSuffix(".app") } ?? []
        guard let name = apps.first else { throw UpdateInstallError.appMissing }
        let dest = dir.appendingPathComponent("OhMyAgent.app")
        guard run("/usr/bin/ditto", [mount.appendingPathComponent(name).path, dest.path]).status == 0 else { throw UpdateInstallError.appMissing }
        return dest
    }

    /// 同步运行子进程(仅用于后台下载任务内的短命令)。
    private static func run(_ tool: String, _ args: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

/// 下载进度观察者。
private final class ProgressObserver: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let report: @Sendable (Double) -> Void
    private var observation: NSKeyValueObservation?
    init(_ report: @escaping @Sendable (Double) -> Void) { self.report = report }
    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        observation = task.progress.observe(\.fractionCompleted) { [report] progress, _ in report(progress.fractionCompleted) }
    }
}
