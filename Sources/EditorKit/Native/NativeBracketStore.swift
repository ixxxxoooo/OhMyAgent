// @author ixxxxoooo
// 括号索引:后台扫描全文括号(跳过字符串与注释),得到每个括号的嵌套深度,供「彩色括号」与「括号匹配」使用。
// 括号以 1 个字符宽的装饰保存,编辑时随 `DecorationSet` 一起平移;后台重扫完成后整体替换。

import AppKit
import EditorCore

/// 括号编码:`.custom(code)`,`code = depth << 4 | type << 1 | isClose`(type: 0 圆括号、1 方括号、2 花括号)。
enum BracketCode {
    static func make(depth: Int, type: Int, isClose: Bool) -> Int { depth << 4 | type << 1 | (isClose ? 1 : 0) }
    static func depth(_ code: Int) -> Int { code >> 4 }
    static func type(_ code: Int) -> Int { (code >> 1) & 7 }
    static func isClose(_ code: Int) -> Bool { code & 1 == 1 }
    /// 未配对的括号用深度 -1 的专用编码(绘制为危险色)。
    static let unmatched = 0x7FFF_0000
}

@MainActor
final class NativeBracketStore {
    /// 括号装饰(只含 `.custom` 括号编码)。
    private(set) var brackets = DecorationSet()
    /// 是否启用(纯文本/Markdown 或超大文件关闭)。
    private(set) var enabled = true
    /// 超过该长度(UTF-16)的文档不做全文括号索引,避免后台长时间占用 CPU。
    static let sizeLimit = 1_500_000
    private var language: SyntaxLanguage = .plain
    private var generation = 0
    private var pending: Task<Void, Never>?
    private var latest: TextRope?
    /// 更新完成回调。
    var onUpdate: (() -> Void)?

    /// 装入文档。
    func load(snapshot: TextRope, language: SyntaxLanguage) {
        self.language = language
        enabled = Self.supports(language) && snapshot.length <= Self.sizeLimit
        latest = snapshot
        brackets = DecorationSet()
        generation += 1
        if enabled { schedule(delay: 0) } else { onUpdate?() }
    }

    /// 编辑:先平移已有括号,再防抖重扫。
    func documentChanged(_ change: DocumentChange) {
        guard enabled || (Self.supports(language) && change.snapshot.length <= Self.sizeLimit) else { return }
        enabled = change.snapshot.length <= Self.sizeLimit && Self.supports(language)
        guard enabled else { brackets = DecorationSet(); return }
        brackets.apply(edits: change.edits)
        latest = change.snapshot
        schedule(delay: 0.18)
    }

    /// 安装扫描结果(后台完成时调用,测试也直接使用)。
    func install(_ items: [Decoration]) {
        var set = DecorationSet()
        set.replaceAll(items)
        brackets = set
        onUpdate?()
    }

    static func supports(_ language: SyntaxLanguage) -> Bool {
        switch language {
        case .plain, .markdown: false
        default: true
        }
    }

    private func schedule(delay: TimeInterval) {
        pending?.cancel()
        generation += 1
        let token = generation
        let language = self.language
        pending = Task { @MainActor [weak self] in
            if delay > 0 { try? await Task.sleep(for: .milliseconds(Int(delay * 1000))) }
            guard !Task.isCancelled, let self, let snapshot = self.latest else { return }
            let items = await Task.detached(priority: .utility) { Self.scan(snapshot: snapshot, language: language) }.value
            guard !Task.isCancelled, token == self.generation else { return }
            self.install(items)
        }
    }

    /// 全文扫描(纯函数,后台线程调用)。
    nonisolated static func scan(snapshot: TextRope, language: SyntaxLanguage) -> [Decoration] {
        let text = snapshot.string()
        // 字符串/注释区间:括号不计入。
        let ignored = SimpleLexer.lex(text, language: language).filter { $0.kind == .string || $0.kind == .comment }
        var result: [Decoration] = []
        var stack: [(type: Int, index: Int)] = []
        var ignoreIndex = 0
        var offset = 0
        var nextID = 0
        snapshot.forEachChunk(in: TextSpan(location: 0, length: snapshot.length)) { chunk in
            for unit in chunk {
                defer { offset += 1 }
                let isOpen = unit == 0x28 || unit == 0x5B || unit == 0x7B
                let isClose = unit == 0x29 || unit == 0x5D || unit == 0x7D
                guard isOpen || isClose else { continue }
                while ignoreIndex < ignored.count, ignored[ignoreIndex].location + ignored[ignoreIndex].length <= offset { ignoreIndex += 1 }
                if ignoreIndex < ignored.count, ignored[ignoreIndex].location <= offset { continue }
                let type = (unit == 0x28 || unit == 0x29) ? 0 : (unit == 0x5B || unit == 0x5D) ? 1 : 2
                if isOpen {
                    result.append(Decoration(id: nextID, range: TextSpan(location: offset, length: 1),
                                             kind: .custom(BracketCode.make(depth: stack.count, type: type, isClose: false)), removesWhenCollapsed: true))
                    stack.append((type, result.count - 1))
                } else if let top = stack.last, top.type == type {
                    stack.removeLast()
                    result.append(Decoration(id: nextID, range: TextSpan(location: offset, length: 1),
                                             kind: .custom(BracketCode.make(depth: stack.count, type: type, isClose: true)), removesWhenCollapsed: true))
                } else {
                    result.append(Decoration(id: nextID, range: TextSpan(location: offset, length: 1),
                                             kind: .custom(BracketCode.unmatched), removesWhenCollapsed: true))
                }
                nextID += 1
            }
        }
        // 栈里剩下的是未闭合的开括号。
        for entry in stack { result[entry.index].kind = .custom(BracketCode.unmatched) }
        return result
    }

    // MARK: 匹配

    /// 找出与 `offset` 处(或其前一个字符)括号配对的括号偏移。
    /// - Returns: `(当前括号偏移, 配对括号偏移)`;没有括号或未配对返回 nil
    func match(at offset: Int, rope: TextRope) -> (Int, Int)? {
        guard enabled else { return nil }
        for candidate in [offset, offset - 1] where candidate >= 0 && candidate < rope.length {
            guard let unit = rope.unit(at: candidate), "()[]{}".utf16.contains(unit) else { continue }
            let window = TextSpan(location: max(candidate - 120_000, 0), length: min(240_000, rope.length - max(candidate - 120_000, 0)))
            let items = brackets.intersecting(window)
            guard let index = items.firstIndex(where: { $0.range.location == candidate }),
                  case .custom(let code) = items[index].kind, code != BracketCode.unmatched else { continue }
            let type = BracketCode.type(code)
            let depth = BracketCode.depth(code)
            if BracketCode.isClose(code) {
                var cursor = index - 1
                while cursor >= 0 {
                    if case .custom(let other) = items[cursor].kind, other != BracketCode.unmatched,
                       BracketCode.type(other) == type, BracketCode.depth(other) == depth, !BracketCode.isClose(other) {
                        return (candidate, items[cursor].range.location)
                    }
                    cursor -= 1
                }
            } else {
                var cursor = index + 1
                while cursor < items.count {
                    if case .custom(let other) = items[cursor].kind, other != BracketCode.unmatched,
                       BracketCode.type(other) == type, BracketCode.depth(other) == depth, BracketCode.isClose(other) {
                        return (candidate, items[cursor].range.location)
                    }
                    cursor += 1
                }
            }
        }
        return nil
    }
}
