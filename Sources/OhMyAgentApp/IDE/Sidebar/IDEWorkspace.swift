// @author ixxxxoooo
// IDE 窗口的工作区上下文:每窗口一份,持有文件树、选择、文件操作撤销栈,
// 并把「打开文件/新建/重命名/删除/拖放」落到窗口模型(`IDEWindowModel`)的标签上。

import AppKit
import ChatKit
import IDEKit
import Observation
import OMLog
import WorkbenchKit

@MainActor
@Observable
final class IDEWorkspace {
    /// 窗口模型
    let model: IDEWindowModel
    /// 文件树(每窗口独立)
    let tree = ExplorerTree()
    /// 资源管理器当前选中的路径(按点击顺序)
    var selection: [String] = []
    /// 请求滚动并选中的路径(`reveal` 设置,视图消费后清空)
    var revealPath: String?
    /// 撤销栈(只记录本窗口资源管理器内的文件操作)
    @ObservationIgnored private(set) var history = FileOpHistory()

    /// - Parameter model: 窗口模型
    init(model: IDEWindowModel) {
        self.model = model
    }

    /// 工作区根目录;未打开文件夹为 nil。
    var root: String? { model.workspaceRoot }

    /// 按当前根目录配置文件树。
    func configureTree() {
        guard let root else { tree.configure([]); return }
        tree.configure([ExplorerSource(root: root, showsHeader: false)])
    }

    // MARK: 打开与定位

    /// 打开文件标签。
    /// - Parameters:
    ///   - path: 文件路径
    ///   - preview: 是否预览方式
    ///   - beside: 是否在侧边分屏打开
    func open(_ path: String, preview: Bool = true, beside: Bool = false) {
        model.openFile(path, preview: preview, beside: beside)
    }

    /// 在文件树中定位并选中某路径(展开所有祖先)。
    /// - Parameter path: 工作区内的绝对路径
    func reveal(_ path: String) {
        guard let root, path.hasPrefix(root + "/") else { return }
        var current = root
        for component in path.dropFirst(root.count + 1).split(separator: "/").dropLast() {
            current += "/" + component
            tree.expand(current)
        }
        revealPath = path
    }

    // MARK: 文件操作

    /// 弹框输入名称后新建文件或文件夹。
    /// - Parameters:
    ///   - directory: 目标目录
    ///   - isDirectory: 是否新建文件夹
    func create(in directory: String, isDirectory: Bool) {
        guard let name = OMDialog.prompt(title: isDirectory ? String(localized: "新建文件夹") : String(localized: "新建文件"),
                                         validate: { Self.nameError($0) }), Self.isValidName(name) else { return }
        let target = (directory as NSString).appendingPathComponent(name)
        Task {
            let error = await Task.detached { () -> String? in
                let fm = FileManager.default
                guard !fm.fileExists(atPath: target) else { return String(localized: "已存在同名项目") }
                do {
                    if isDirectory { try fm.createDirectory(atPath: target, withIntermediateDirectories: true) }
                    else { try Data().write(to: URL(fileURLWithPath: target)) }
                    return nil
                } catch { return error.localizedDescription }
            }.value
            if let error { report(error); return }
            Log.editor.info("IDE 新建", ["path": target, "dir": "\(isDirectory)"])
            history.push(FileOpGroup(title: "新建", ops: [.created(path: target)]))
            didChangeFiles()
            tree.expand(directory)
            reveal(target)
            if !isDirectory { open(target, preview: false) }
        }
    }

    /// 弹框重命名。
    /// - Parameter path: 目标路径
    func rename(_ path: String) {
        let oldName = (path as NSString).lastPathComponent
        guard let name = OMDialog.prompt(title: String(localized: "重命名"), initial: oldName, validate: { Self.nameError($0) }),
              Self.isValidName(name), name != oldName else { return }
        let target = ((path as NSString).deletingLastPathComponent as NSString).appendingPathComponent(name)
        Task {
            let error = await Task.detached { () -> String? in
                guard !FileManager.default.fileExists(atPath: target) else { return String(localized: "已存在同名项目") }
                do { try FileManager.default.moveItem(atPath: path, toPath: target); return nil }
                catch { return error.localizedDescription }
            }.value
            if let error { report(error); return }
            Log.editor.info("IDE 重命名", ["from": path, "to": target])
            history.push(FileOpGroup(title: "重命名", ops: [.move(from: path, to: target)]))
            model.retargetFileTabs(from: path, to: target)
            for key in FileDocumentStore.shared.documents.keys where key == path || key.hasPrefix(path + "/") {
                FileDocumentStore.shared.discard(key)
            }
            didChangeFiles()
            reveal(target)
        }
    }

    /// 确认后把若干路径移到废纸篓。
    /// - Parameter paths: 路径(空数组忽略)
    func trash(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        let title = paths.count == 1
            ? String(localized: "要把「\((paths[0] as NSString).lastPathComponent)」移到废纸篓吗?")
            : String(localized: "要把这 \(paths.count) 个项目移到废纸篓吗?")
        guard OMDialog.confirm(title: title, confirmTitle: String(localized: "移到废纸篓"), destructive: true) else { return }
        Task {
            let result = await Task.detached { () -> (ops: [FileOp], errors: [String]) in
                var ops: [FileOp] = []
                var errors: [String] = []
                for path in paths {
                    do {
                        var resulting: NSURL?
                        try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &resulting)
                        if let trashed = resulting?.path { ops.append(.trashed(original: path, trashed: trashed)) }
                    } catch { errors.append("\((path as NSString).lastPathComponent):\(error.localizedDescription)") }
                }
                return (ops, errors)
            }.value
            if !result.ops.isEmpty { history.push(FileOpGroup(title: "移到废纸篓", ops: result.ops)) }
            for path in paths { model.closeFileTabs(under: path); FileDocumentStore.shared.discard(path) }
            Log.editor.info("IDE 移到废纸篓", ["count": "\(paths.count)", "failed": "\(result.errors.count)"])
            didChangeFiles()
            if !result.errors.isEmpty { report(result.errors.joined(separator: "\n")) }
        }
    }

    /// 复制一份(同目录,名称加「 copy」)。
    /// - Parameter path: 源路径
    func duplicate(_ path: String) {
        let parent = (path as NSString).deletingLastPathComponent
        let ext = (path as NSString).pathExtension
        let base = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        Task {
            let target = await Task.detached { () -> String? in
                let fm = FileManager.default
                for index in 1...99 {
                    let suffix = index == 1 ? " copy" : " copy \(index)"
                    let name = ext.isEmpty ? base + suffix : "\(base)\(suffix).\(ext)"
                    let candidate = (parent as NSString).appendingPathComponent(name)
                    guard !fm.fileExists(atPath: candidate) else { continue }
                    return (try? fm.copyItem(atPath: path, toPath: candidate)) != nil ? candidate : nil
                }
                return nil
            }.value
            guard let target else { report(String(localized: "无法创建副本")); return }
            history.push(FileOpGroup(title: "复制", ops: [.created(path: target)]))
            didChangeFiles()
            reveal(target)
        }
    }

    /// 回退最近一次文件操作。
    func undo() {
        guard let group = history.popLast() else { return }
        Task {
            let failures = await Task.detached { FileOpReverter.revert(group) }.value
            for op in group.ops {
                switch op {
                case .move(let from, let to): model.retargetFileTabs(from: to, to: from)
                case .created(let path): model.closeFileTabs(under: path)
                case .trashed: break
                }
            }
            didChangeFiles()
            Log.editor.info("IDE 撤销文件操作", ["title": group.title, "failed": "\(failures.count)"])
            if !failures.isEmpty { report(failures.joined(separator: "\n")) }
        }
    }

    /// 是否有可撤销的文件操作。
    var canUndo: Bool { history.canUndo }

    /// 执行拖放规划:工作区内移动、外部复制;同名先询问;有未保存修改的文件不移动。
    /// - Parameters:
    ///   - sources: 源路径
    ///   - directory: 落点文件夹
    func performDrop(sources: [String], into directory: String) {
        guard !sources.isEmpty, let root else { return }
        let plan = ExplorerDropPlan.make(sources: sources, into: directory, workspaceRoots: [root])
        if !plan.rejected.isEmpty { report(String(localized: "不能把文件夹移到它自身或它的子文件夹里。")) }
        let dirty = plan.transfers.filter { transfer in
            transfer.kind == .move && FileDocumentStore.shared.dirtyDocuments.contains { $0.path == transfer.source || $0.path.hasPrefix(transfer.source + "/") }
        }
        if !dirty.isEmpty {
            report(String(localized: "「\(dirty.map { ($0.source as NSString).lastPathComponent }.joined(separator: "、"))」有未保存的修改,请先保存再移动。"))
        }
        var transfers = plan.transfers.filter { !dirty.contains($0) }
        let conflicts = transfers.filter { FileManager.default.fileExists(atPath: $0.destination) }
        if !conflicts.isEmpty {
            let names = conflicts.map { ($0.destination as NSString).lastPathComponent }.joined(separator: "、")
            let replace = OMDialog.confirm(title: String(localized: "目标文件夹中已有同名项目"),
                                           message: String(localized: "「\(names)」已存在。要替换吗?被替换的项目会移到废纸篓。"),
                                           confirmTitle: String(localized: "替换"), destructive: true)
            if !replace { transfers.removeAll { conflicts.contains($0) } }
        }
        guard !transfers.isEmpty else { return }
        let jobs = transfers
        Task {
            let (failures, ops) = await Task.detached { Self.run(jobs) }.value
            history.push(FileOpGroup(title: "拖放", ops: ops))
            for job in jobs where job.kind == .move && FileManager.default.fileExists(atPath: job.destination) {
                model.retargetFileTabs(from: job.source, to: job.destination)
                for key in FileDocumentStore.shared.documents.keys where key == job.source || key.hasPrefix(job.source + "/") {
                    FileDocumentStore.shared.discard(key)
                }
            }
            Log.editor.info("IDE 拖放", ["into": directory, "jobs": "\(jobs.count)", "failed": "\(failures.count)"])
            didChangeFiles()
            tree.expand(directory)
            if !failures.isEmpty { report(failures.joined(separator: "\n")) }
        }
    }

    // MARK: 内部

    /// 后台执行传输作业(同名目标先移到废纸篓)。
    nonisolated private static func run(_ jobs: [ExplorerTransfer]) -> ([String], [FileOp]) {
        let fm = FileManager.default
        var failures: [String] = []
        var ops: [FileOp] = []
        for job in jobs {
            do {
                if fm.fileExists(atPath: job.destination) {
                    var resulting: NSURL?
                    try fm.trashItem(at: URL(fileURLWithPath: job.destination), resultingItemURL: &resulting)
                    if let trashed = resulting?.path { ops.append(.trashed(original: job.destination, trashed: trashed)) }
                }
                switch job.kind {
                case .move: try fm.moveItem(atPath: job.source, toPath: job.destination); ops.append(.move(from: job.source, to: job.destination))
                case .copy: try fm.copyItem(atPath: job.source, toPath: job.destination); ops.append(.created(path: job.destination))
                }
            } catch { failures.append("\((job.source as NSString).lastPathComponent):\(error.localizedDescription)") }
        }
        return (failures, ops)
    }

    /// 文件变化后刷新树与索引。
    private func didChangeFiles() {
        ExplorerModel.shared.bump()
        if let root { WorkspaceIndexModel.shared.refresh(root: root) }
        tree.refresh()
    }

    private func report(_ message: String) {
        Log.ui.warning("IDE 文件操作失败", ["error": message])
        OMDialog.alert(title: String(localized: "操作失败"), message: message, isError: true)
    }

    /// 名称是否合法:不能含 `/`,也不能是 `.`/`..`。
    nonisolated static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && name != "." && name != ".."
    }

    /// 名称校验文案(合法返回 nil)。
    nonisolated static func nameError(_ name: String) -> String? {
        isValidName(name) ? nil : String(localized: "名称不能包含 / 或为 . 与 ..")
    }
}
