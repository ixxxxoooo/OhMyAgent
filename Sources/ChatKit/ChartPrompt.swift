// @author ixxxxoooo
// 会话内联图表的系统提示:告诉 Agent 可用 ```chart 围栏在回复里画折线/柱状/面积/饼图。

import Foundation

/// 会话图表提示词(追加到系统提示末尾)。
public enum ChartPrompt {
    /// 追加提示文本。
    public static let text = """
    当用户需要查看趋势、对比或占比时,可在回复中直接画图:输出语言标记为 chart 的代码围栏,内容为 JSON,界面会把它渲染成图表。格式:
    ```chart
    {"kind":"line","title":"标题","labels":["1月","2月","3月"],"series":[{"name":"系列名","values":[10,20,15]}]}
    ```
    kind 可选 line(折线)、bar(柱状)、area(面积)、pie(饼图,只能 1 个系列);每个系列的 values 数量必须与 labels 一致,数据点不超过 1000;JSON 必须合法(不要注释、不要尾随逗号)。需要多条折线时在 series 里放多个系列。更复杂的流程/时序图用 mermaid 围栏。
    """
}
