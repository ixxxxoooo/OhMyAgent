// @author ixxxxoooo
// 会话内联图表的系统提示:告诉 Agent 可用 ```chart 围栏在回复里画折线/柱状/面积/饼图。

import Foundation

/// 会话图表提示词(追加到系统提示末尾)。
public enum ChartPrompt {
    /// 追加提示文本。
    public static let text = """
    需要画趋势/对比/占比图时,输出 ```chart 围栏,内容为 JSON:{"kind":"line|bar|area|pie","title":"…","labels":["a","b"],"series":[{"name":"…","values":[1,2]}]}(values 数量须与 labels 一致,JSON 必须合法)。流程图/时序图用 mermaid;不要用 mermaid 的 xychart-beta 画数据图。
    """
}
