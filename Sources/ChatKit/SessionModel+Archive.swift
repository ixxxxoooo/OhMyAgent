// @author ixxxxoooo
// 会话模型与会话存档的接线:原始更新落盘、用户消息补记(引擎不回显用户自己发的消息)、回合结束写盘。

import ACPKit
import Foundation

extension SessionModel {
    /// 应用使用的会话存档;nil 表示不存档(单元测试默认不写真实数据目录,由应用启动时设置为 `.shared`)。
    @MainActor public static var archive: SessionArchive?

    /// 当前引擎下某个会话的存档键。
    /// - Parameter sessionId: 协议会话 ID
    func archiveKey(_ sessionId: String) -> SessionArchiveKey {
        SessionArchiveKey(agentId: activeDescriptor.id, sessionId: sessionId)
    }

    /// 把客户端的原始更新接到存档(在 `ACPClient` 解析之前按到达顺序回调)。
    /// - Parameter client: 当前连接
    func installArchiveTap(on client: ACPClient) {
        guard let archive = Self.archive else {
            client.setUpdateTap(nil)
            return
        }
        let agentId = activeDescriptor.id
        let cwd = workspace.path
        client.setUpdateTap { sessionId, update in
            archive.record(SessionArchiveKey(agentId: agentId, sessionId: sessionId), cwd: cwd, update: update)
        }
    }

    /// 补记用户发出的消息:只记文本与图片(与时间线展示一致),同一条消息共用一个消息 ID。
    /// - Parameters:
    ///   - text: 消息文本
    ///   - images: 图片附件
    ///   - sessionId: 协议会话 ID
    func archiveUserMessage(_ text: String, images: [ImageAttachment], sessionId: String) {
        guard let archive = Self.archive else { return }
        let key = archiveKey(sessionId)
        let messageId = "oma-user-" + UUID().uuidString.lowercased()
        var blocks: [ContentBlock] = text.isEmpty ? [] : [.text(text)]
        blocks += images.map(\.contentBlock)
        for block in blocks {
            archive.record(key, cwd: workspace.path, update: ["sessionUpdate": "user_message_chunk", "messageId": .string(messageId), "content": block.json])
        }
    }

    /// 回合结束:把该会话合并中的内容与缓冲写盘。
    /// - Parameter sessionId: 协议会话 ID
    func flushArchive(_ sessionId: String?) {
        guard let archive = Self.archive, let sessionId else { return }
        archive.flush(archiveKey(sessionId))
    }
}
