// @author ixxxxoooo
// 工具面板标签:把右栏的文件 / 搜索 / Git 拖进编辑区后的内容,可像其他标签一样分屏或并入标签组。

import DesignSystem
import SwiftUI
import WorkbenchKit

/// 编辑区里的工具面板(文件 / 搜索 / Git),复用右栏同一套视图。
struct ToolsTabView: View {
    @Bindable var workbench: WorkbenchModel
    /// 要显示的右栏视图
    let pane: RightPane

    var body: some View {
        Group {
            switch pane {
            case .git: SCMView(workbench: workbench)
            case .search: SearchPaneView(workbench: workbench)
            default: ExplorerView(workbench: workbench)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(OMColors.surface)
    }
}
