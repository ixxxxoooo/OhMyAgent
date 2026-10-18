// @author ixxxxoooo
// 蜡烛图(K 线)数据:一根蜡烛 = 开高低收 + 可选成交量;宽松解码(数组 [o,h,l,c,v?] 或对象)、校验与均线计算。

import Foundation

/// 一根蜡烛。
public struct CanvasCandle: Codable, Sendable, Equatable {
    public var open: Double
    public var high: Double
    public var low: Double
    public var close: Double
    public var volume: Double?

    public init(open: Double, high: Double, low: Double, close: Double, volume: Double? = nil) {
        self.open = open
        self.high = high
        self.low = low
        self.close = close
        self.volume = volume
    }

    /// 是否收涨(收盘不低于开盘)。
    public var isUp: Bool { close >= open }

    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int?
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { self.stringValue = "\(intValue)"; self.intValue = intValue }
    }

    /// 数字或数字字符串。
    private struct Num: Decodable {
        let value: Double
        init(from decoder: Decoder) throws {
            let single = try decoder.singleValueContainer()
            if let number = try? single.decode(Double.self) { value = number; return }
            if let text = try? single.decode(String.self), let number = Double(text.replacingOccurrences(of: ",", with: "")) { value = number; return }
            throw DecodingError.typeMismatch(Double.self, .init(codingPath: decoder.codingPath, debugDescription: "蜡烛数据需要数字"))
        }
    }

    /// 解码:数组 `[open, high, low, close, volume?]` 或对象(键 open/high/low/close/volume,可简写 o/h/l/c/v)。
    public init(from decoder: Decoder) throws {
        if var list = try? decoder.unkeyedContainer() {
            var numbers: [Double] = []
            while !list.isAtEnd { numbers.append(try list.decode(Num.self).value) }
            guard numbers.count == 4 || numbers.count == 5 else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "蜡烛数组必须是 [open, high, low, close] 或再加 volume"))
            }
            self.init(open: numbers[0], high: numbers[1], low: numbers[2], close: numbers[3], volume: numbers.count == 5 ? numbers[4] : nil)
            return
        }
        let c = try decoder.container(keyedBy: Key.self)
        func number(_ names: String...) throws -> Double? {
            for name in names {
                if let key = Key(stringValue: name), c.contains(key) { return try c.decode(Num.self, forKey: key).value }
            }
            return nil
        }
        guard let o = try number("open", "o"), let h = try number("high", "h"), let l = try number("low", "l"), let cl = try number("close", "c") else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "蜡烛对象需要 open/high/low/close"))
        }
        self.init(open: o, high: h, low: l, close: cl, volume: try number("volume", "v"))
    }

    /// 编码为紧凑数组 `[o, h, l, c, v?]`。
    public func encode(to encoder: Encoder) throws {
        var list = encoder.unkeyedContainer()
        for value in [open, high, low, close] { try list.encode(value) }
        if let volume { try list.encode(volume) }
    }

    /// 校验蜡烛图:labels 与 candles 等长、数量上限、最高/最低价自洽、均线周期合法。
    /// - Parameters:
    ///   - chart: 蜡烛图
    ///   - path: 错误信息里的路径前缀
    /// - Throws: `CanvasError`
    static func validate(_ chart: CanvasChart, path: String) throws {
        guard !chart.candles.isEmpty else { throw CanvasError("\(path) 蜡烛图需要非空的 candles(每根 [open, high, low, close, volume?])") }
        guard chart.candles.count <= CanvasLimits.maxChartPoints else { throw CanvasError("\(path) 数据点过多(上限 \(CanvasLimits.maxChartPoints))") }
        guard chart.labels.count == chart.candles.count else {
            throw CanvasError("\(path).candles 数量(\(chart.candles.count))必须与 labels(\(chart.labels.count))一致")
        }
        for (index, candle) in chart.candles.enumerated() {
            guard candle.high >= max(candle.open, candle.close), candle.low <= min(candle.open, candle.close) else {
                throw CanvasError("\(path).candles[\(index)] 的最高价必须 ≥ 开盘/收盘,最低价必须 ≤ 开盘/收盘")
            }
        }
        guard chart.movingAverages.allSatisfy({ (2...250).contains($0) }) else { throw CanvasError("\(path).ma 的周期必须在 2~250 之间") }
    }
}

public extension CanvasChart {
    /// 收盘价简单移动平均;前 `period - 1` 根为 nil。
    /// - Parameter period: 周期(≥ 2)
    /// - Returns: 与 `candles` 等长的数组
    func movingAverage(period: Int) -> [Double?] {
        guard period >= 2 else { return Array(repeating: nil, count: candles.count) }
        var result: [Double?] = []
        var sum = 0.0
        for (index, candle) in candles.enumerated() {
            sum += candle.close
            if index >= period { sum -= candles[index - period].close }
            result.append(index >= period - 1 ? sum / Double(period) : nil)
        }
        return result
    }
}
