// @author ixxxxoooo
// 会话内联图表的系统提示:告诉 Agent 可用 ```chart 围栏在回复里画折线/柱状/面积/饼图。

import Foundation

/// 会话图表提示词(追加到系统提示末尾)。
public enum ChartPrompt {
    /// 追加提示文本。
    public static let text = """
    需要在回复里画图(折线/柱状/饼图,或股票 K 线)时,先调用 chart_guide 工具获取格式,再输出 ```chart 围栏;流程图/时序图用 mermaid。图中数据必须来自真实检索,估算或示意的数据要在标题里注明。
    """
}
