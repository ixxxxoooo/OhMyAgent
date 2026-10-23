// @author ixxxxoooo
// 偏移映射:把「编辑前」的偏移经过一串原子编辑映射到「编辑后」的偏移。选区、装饰、折叠都依赖它保持位置。

import Foundation

/// 偏移落在插入点/删除区间边缘时的倾向。
public enum MappingBias: Sendable {
    /// 偏向编辑之前(插入点上的偏移留在插入文本之前)。
    case left
    /// 偏向编辑之后(插入点上的偏移移到插入文本之后)。
    case right
}

public enum OffsetMapping {
    /// 把偏移依次经过各编辑(按应用顺序)映射。
    /// - Parameters:
    ///   - offset: 编辑前偏移
    ///   - edits: 按应用顺序排列的原子编辑
    ///   - bias: 恰好落在编辑起点(纯插入)时的倾向
    /// - Returns: 编辑后的偏移
    public static func map(_ offset: Int, through edits: [AppliedEdit], bias: MappingBias) -> Int {
        var position = offset
        for edit in edits { position = map(position, through: edit, bias: bias) }
        return position
    }

    /// 经过单个编辑。
    public static func map(_ offset: Int, through edit: AppliedEdit, bias: MappingBias) -> Int {
        let end = edit.location + edit.oldLength
        if offset < edit.location { return offset }
        if offset > end { return offset + edit.newLength - edit.oldLength }
        // 落在 [location, end] 内。
        if offset == edit.location && edit.oldLength == 0 {
            return bias == .right ? offset + edit.newLength : offset
        }
        if offset == edit.location { return offset }
        if offset == end { return edit.location + edit.newLength }
        // 落在被替换区间内部:坍缩到替换文本的一端。
        return bias == .right ? edit.location + edit.newLength : edit.location
    }
}
