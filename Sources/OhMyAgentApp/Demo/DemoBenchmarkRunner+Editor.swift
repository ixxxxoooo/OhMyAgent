// @author ixxxxoooo
// 原生编辑器(native2)基准:调用 `EditorKit.NativeEditorBench`,把结果挂到 `editor.*` 度量点(带 120Hz 预算)。
// 与 `ide.*`(整窗口场景、随 `editor.engine` 切换引擎)互补:这里直接量 `OMEditorView` 内核,不受 SwiftUI 外壳影响。

import DemoKit
import EditorKit
import Foundation
import OMLog

extension DemoBenchmarkRunner {
    /// 运行全部原生编辑器基准。
    func runEditor() async {
        setPhase("原生编辑器")
        let results = await NativeEditorBench.run { [weak self] step in self?.currentStep = step }
        for result in results {
            report.record(updated(result.id) { $0.value = result.value; $0.detail = result.detail })
            Log.perf.info("编辑器基准项", ["id": result.id, "value": String(format: "%.2f", result.value), "detail": result.detail])
        }
    }
}
