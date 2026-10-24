// @author ixxxxoooo
// IDE 侧栏「源代码管理」视图:与 Agent 窗口右栏共用同一套 `SCMContent`(分支切换、拉取/推送、
// 提交与修补、AI 提交说明、stash、冲突解决、变更分组、提交图谱);差异/文件/历史标签落到 IDE 窗口。

import GitKit
import SwiftUI

struct IDESCMPane: View {
    let workspace: IDEWorkspace

    var body: some View {
        if let root = workspace.root {
            SCMContent(host: IDESCMHost(workspace: workspace), model: GitStore.shared.model(for: root))
                .id(root)
        }
    }
}
