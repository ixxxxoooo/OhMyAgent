// @author ixxxxoooo
// 新建自定义斜杠命令向导:名称、描述、参数提示、位置;写入 `<scope>/.claude/commands/<name>.md`。

import ClaudeConfigKit
import DesignSystem
import SwiftUI

/// 新建命令向导。
struct CommandCreateSheet: View {
    let center: ConfigCenter
    let onClose: () -> Void
    @State private var name = ""
    @State private var description = ""
    @State private var argumentHint = ""
    @State private var scope: ConfigScope = .user

    private var problems: [String] {
        name.range(of: "^[a-z0-9][a-z0-9-]{0,63}$", options: .regularExpression) == nil ? [String(localized: "名称只能包含小写字母、数字和连字符")] : []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("新建命令").font(OMFonts.title)
            FormRow(label: String(localized: "名称"), hint: String(localized: "在输入框用 /\(name.isEmpty ? "name" : name) 触发")) { TextField("review-pr", text: $name).textFieldStyle(.omField) }
            FormRow(label: String(localized: "描述")) { TextField("它做什么,显示在命令补全里", text: $description).textFieldStyle(.omField) }
            FormRow(label: String(localized: "参数提示"), hint: String(localized: "可选:命令名后面要填什么,如 [PR 编号]")) { TextField("[PR 编号]", text: $argumentHint).textFieldStyle(.omField) }
            FormRow(label: String(localized: "位置")) {
                Picker("", selection: $scope) { Text("用户").tag(ConfigScope.user); Text("项目").tag(ConfigScope.project) }.pickerStyle(.segmented).labelsHidden()
            }
            SheetFooter(problems: problems, confirmTitle: String(localized: "创建"), onCancel: onClose) {
                if center.perform(String(localized: "已创建 \(name)"), { try SkillStore(paths: center.paths).createCommand(name: name, description: description, argumentHint: argumentHint, scope: scope) }) { onClose() }
            }
        }
        .padding(20)
        .frame(width: 500)
    }
}
