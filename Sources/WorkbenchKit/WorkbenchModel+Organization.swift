// @author ixxxxoooo
// 工作台的会话置顶/归档、项目图标与多文件夹工作区(从 WorkbenchModel 拆出,保持主文件可读)。

import ChatKit
import DiffKit
import Foundation
import OMLog

extension WorkbenchModel {
    private var log: OMLogger { Log.session }

    // MARK: 会话置顶与归档

    /// 会话是否已置顶。
    public func isSessionPinned(_ sessionId: String, in project: String) -> Bool {
        projects.first { $0.id == project }?.pinnedSessions.contains(sessionId) ?? false
    }

    /// 会话是否已归档。
    public func isSessionArchived(_ sessionId: String, in project: String) -> Bool {
        projects.first { $0.id == project }?.archivedSessions.contains(sessionId) ?? false
    }

    /// 切换会话置顶(归档的会话置顶时自动取消归档)。
    public func toggleSessionPin(_ sessionId: String, in project: String) {
        guard !sessionId.isEmpty, let index = projects.firstIndex(where: { $0.id == project }) else { return }
        if let at = projects[index].pinnedSessions.firstIndex(of: sessionId) {
            projects[index].pinnedSessions.remove(at: at)
        } else {
            projects[index].pinnedSessions.append(sessionId)
            projects[index].archivedSessions.removeAll { $0 == sessionId }
        }
        scheduleSave()
    }

    /// 归档或取消归档会话(归档同时取消置顶)。
    public func setSessionArchived(_ archived: Bool, sessionId: String, in project: String) {
        guard !sessionId.isEmpty, let index = projects.firstIndex(where: { $0.id == project }) else { return }
        projects[index].archivedSessions.removeAll { $0 == sessionId }
        if archived {
            projects[index].archivedSessions.append(sessionId)
            projects[index].pinnedSessions.removeAll { $0 == sessionId }
        }
        scheduleSave()
    }

    /// 重命名会话:标题写入客户端偏好(适配器没有改名接口),并同步缓存与已打开的会话。
    /// - Parameters:
    ///   - sessionId: 协议会话 ID
    ///   - project: 项目 ID
    ///   - title: 新标题(去除首尾空白后不能为空)
    public func renameSession(_ sessionId: String, in project: String, to title: String) {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sessionId.isEmpty, !clean.isEmpty, let index = projects.firstIndex(where: { $0.id == project }) else { return }
        ClientPrefs.setSessionTitle(clean, for: sessionId)
        if let at = projects[index].sessions.firstIndex(where: { $0.sessionId == sessionId }) { projects[index].sessions[at].title = clean }
        for (key, model) in conversations where key.projectID == project { model.applyRenamedTitle(clean, sessionId: sessionId) }
        for tab in dock.allTabs {
            if case .chat(let p, let slot) = tab.kind, p == project, conversations[ConversationKey(projectID: p, slot: slot)]?.sessionId == sessionId {
                dock.setTitle(clean, for: tab.id)
            }
        }
        scheduleSave()
    }

    /// 批量归档会话(归档同时取消置顶)。
    /// - Parameters:
    ///   - sessionIds: 会话 ID 列表
    ///   - project: 项目 ID
    public func archiveSessions(_ sessionIds: [String], in project: String) {
        guard let index = projects.firstIndex(where: { $0.id == project }) else { return }
        var seen = Set<String>()
        let ordered = sessionIds.filter { !$0.isEmpty && seen.insert($0).inserted }
        guard !ordered.isEmpty else { return }
        let ids = Set(ordered)
        projects[index].archivedSessions.removeAll { ids.contains($0) }
        projects[index].archivedSessions.append(contentsOf: ordered)
        projects[index].pinnedSessions.removeAll { ids.contains($0) }
        scheduleSave()
    }

    /// 归档某项目下的全部会话(包含已缓存与当前打开的,当前空白对话除外)。
    public func archiveAllSessions(in project: String) {
        guard let entry = projects.first(where: { $0.id == project }) else { return }
        var ids = entry.sessions.map(\.sessionId)
        for (key, model) in conversations where key.projectID == project { if let id = model.sessionId { ids.append(id) } }
        var seen = Set<String>()
        archiveSessions(ids.filter { seen.insert($0).inserted }, in: project)
    }

    /// 修改项目在侧栏中显示的名称(不改磁盘上的目录名)。
    /// - Parameters:
    ///   - id: 项目 ID
    ///   - name: 新名称(去除首尾空白后不能为空)
    public func renameProject(_ id: String, to name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let index = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[index].name = clean
        scheduleSave()
    }

    // MARK: 项目图标

    /// 图标图片目录:与状态文件同级的 `ProjectIcons`(演示模式因状态文件隔离而自动隔离)。
    public var projectIconDirectory: URL {
        store.fileURL.deletingLastPathComponent().appendingPathComponent("ProjectIcons", isDirectory: true)
    }

    /// 设置(或清除)项目图标;替换掉旧的图片图标时删除旧文件。
    /// - Parameters:
    ///   - icon: 新图标;nil 恢复默认
    ///   - id: 项目 ID
    public func setProjectIcon(_ icon: ProjectIcon?, for id: String) {
        guard let index = projects.firstIndex(where: { $0.id == id }), projects[index].icon != icon else { return }
        let old = projects[index].icon
        projects[index].icon = icon
        if old?.kind == .image, old != icon { ProjectIconFiles.removeFile(for: old, in: projectIconDirectory) }
        scheduleSave()
    }

    /// 导入图片作为图标(复制到图标目录)。
    /// - Returns: 成功返回图片图标(尚未应用到任何项目)
    public func importProjectIcon(imageAt url: URL) -> ProjectIcon? {
        ProjectIconFiles.importImage(from: url, into: projectIconDirectory)
    }

    // MARK: 多文件夹工作区

    /// 工作区的全部根目录(主目录在前);项目不存在时为空。
    public func allRoots(of id: String) -> [String] {
        projects.first(where: { $0.id == id })?.allRoots ?? []
    }

    /// 给工作区添加一个附加文件夹。已打开的会话需重新建立才会让 Agent 获得新目录的访问范围。
    /// - Parameters:
    ///   - path: 文件夹路径
    ///   - id: 项目 ID
    /// - Returns: 成功返回规范化路径;失败给出原因
    @discardableResult
    public func addFolder(_ path: String, to id: String, requireExists: Bool = true) -> Result<String, WorkspaceFolderError> {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return .failure(.notDirectory) }
        let result = WorkspaceFolders.validate(path, primary: id, existing: projects[index].extraFolders, requireExists: requireExists)
        if case .success(let normalized) = result {
            projects[index].extraFolders.append(normalized)
            workspaceFoldersChanged(project: id)
            log.info("工作区添加文件夹", ["project": id, "folder": normalized])
        }
        return result
    }

    /// 从工作区移除一个附加文件夹(只改工作区配置,不动磁盘)。
    /// - Parameters:
    ///   - path: 文件夹路径
    ///   - id: 项目 ID
    public func removeFolder(_ path: String, from id: String) {
        guard let index = projects.firstIndex(where: { $0.id == id }), projects[index].extraFolders.contains(path) else { return }
        projects[index].extraFolders.removeAll { $0 == path }
        workspaceFoldersChanged(project: id)
        log.info("工作区移除文件夹", ["project": id, "folder": path])
    }

    /// 附加文件夹变化后:刷新会话参数、丢弃不含新目录的待命会话、保存。
    private func workspaceFoldersChanged(project id: String) {
        let extras = projects.first(where: { $0.id == id })?.extraFolders ?? []
        for (key, model) in conversations where key.projectID == id { model.additionalDirectories = extras }
        warmPool.discard(workspace: id)
        scheduleSave()
    }

    /// 领取预热会话;带附加文件夹的工作区不使用预热会话(预热时无法得知附加目录)。
    /// - Parameters:
    ///   - agentID: 引擎 ID
    ///   - project: 项目
    public func takeWarmSession(agentID: String, project: ProjectEntry) -> SessionModel? {
        guard !project.isMultiRoot, !project.isChatArea, let model = warmPool.take(agentID: agentID, workspace: project.url) else { return nil }
        onWarmSessionTaken?()
        return model
    }
}
