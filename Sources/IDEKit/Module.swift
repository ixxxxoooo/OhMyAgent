// @author ixxxxoooo
// IDEKit:IDE 模式的数据层(无视图)。
// 已有:`IDEWindowSnapshot`/`IDEMetrics`(快照与度量)、`IDEWindowModel`(每窗一份)、`IDEWindowRegistry`(多窗口与持久化)、
// `IDEWindowStore`(`ide-windows.json`)。
// 后续里程碑加入 `IDECommandRegistry`、`ProblemsStore`、`IDEStatusModel`;
// 设计见 `.specstory/history/docs/20261021_IDE模式开发计划.md`。

import Foundation

/// IDEKit 模块标识。
public enum IDEKitModule {
    /// 模块名。
    public static let name = "IDEKit"
}
