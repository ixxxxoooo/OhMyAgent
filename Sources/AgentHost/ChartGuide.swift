// @author ixxxxoooo
// Bridge 工具 `chart_guide` 的返回内容:会话内联图表(```chart 围栏)的完整格式说明。
// 放在工具里按需取用,系统提示只留一句指引,避免每轮都带上长说明。

import Foundation

/// 图表格式说明。
public enum ChartGuide {
    /// 完整说明(给模型看,英文)。
    public static let text = """
    OhMyAgent renders a fenced code block with language `chart` (content = one JSON object) as a native chart inside the chat. \
    Emit it directly in your reply; do not wrap it in another fence. The JSON must be valid (no comments, no trailing commas).

    1) Line / bar / area / pie
    ```chart
    {"kind":"line","title":"Monthly sales","labels":["Jan","Feb","Mar"],"series":[{"name":"2025","values":[10,20,15]},{"name":"2026","values":[12,18,25]}]}
    ```
    - kind: line | bar | area | pie. Every series' `values` length must equal `labels` length. Pie takes exactly 1 series. Max 1000 points.

    2) Candlestick / K-line (stocks, crypto, FX)
    ```chart
    {"kind":"candle","title":"600519 daily (demo data)","labels":["10-14","10-15","10-16"],\
    "candles":[[1500,1530,1490,1520,32000],[1520,1540,1505,1510,28000],[1510,1560,1508,1555,41000]],"ma":[5,10],"up":"red"}
    ```
    - candles: one per label, each `[open, high, low, close, volume?]` (objects with open/high/low/close/volume also work). high must be >= open and close; low must be <= open and close.
    - labels: dates or times, same length as candles. ma: optional moving-average periods (2-250) computed from closes by the client. \
    volume is optional; if present a volume panel is drawn. up: "red" (default, red = up, China style) or "green" (green = up).
    - Hovering shows each candle's OHLC and change.

    Rules: only use real data you actually retrieved. If the numbers are illustrative or estimated, say so in the title (e.g. "demo data"). \
    Do not use mermaid xychart-beta for data charts. Use mermaid for flowcharts and sequence diagrams.
    """
}
