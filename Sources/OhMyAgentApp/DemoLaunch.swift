// @author ixxxxoooo
// 演示模式启动接入:在任何读取用户数据的代码之前准备沙盒并重定向主目录;提供「演示模式」徽标视图。

import ChatKit
import DemoKit
import DesignSystem
import Foundation
import OMLog
import SwiftUI

/// 演示模式的进程级状态(`OMA_DEMO=1` 时启用)。
@MainActor
enum DemoLaunch {
    /// 当前演示环境;未启用时为 nil
    private(set) static var environment: DemoEnvironment?
    /// 演示项目列表
    private(set) static var projects: [DemoProjectInfo] = []

    /// 是否处于演示模式。
    static var isActive: Bool { environment != nil }

    /// 若请求了演示模式:准备沙盒 → 重定向主目录 → 切换最近项目存储。必须在 `AppEnvironment.shared` 之前调用。
    static func activateIfRequested() {
        guard let demo = DemoEnvironment.current() else { return }
        environment = demo
        projects = demo.prepareBlocking()
        demo.redirectHome()
        RecentStore.useSuite(DemoEnvironment.defaultsSuiteName)
        Log.app.info("演示模式已启用", ["root": demo.paths.root.path, "projects": "\(projects.count)", "reset": "\(demo.reset)"])
    }
}

/// 左侧栏底部(设置按钮右侧)的「演示」徽章,提醒当前数据来自沙盒、Agent 为脚本化演示 Agent。
struct DemoBadgeView: View {
    var body: some View {
        Text("演示")
            .font(OMFonts.caption.weight(.semibold))
            .foregroundStyle(OMColors.warning)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(OMColors.warning.opacity(0.15), in: OMPillShape())
            .overlay(OMPillShape().strokeBorder(OMColors.warning.opacity(0.4), lineWidth: 0.5))
            .help("演示模式:数据来自沙盒,Agent 为脚本化演示 Agent,不会触碰真实项目与账号")
            .accessibilityLabel("演示模式")
            .allowsHitTesting(true)
    }
}
