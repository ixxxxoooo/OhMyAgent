// @author ygw
// SVG path 数据解析器:M/L/H/V/C/S/Q/T/A/Z(含小写相对形式),圆弧按 SVG 规范转为三次贝塞尔。
// 纯值类型、无副作用,可在任意线程调用。

import CoreGraphics
import Foundation
import SwiftUI

/// 解析错误。
public enum SVGPathError: Error, Equatable {
    case unexpectedCharacter(Character)
    case missingNumber(command: Character)
    case invalidFlag
    case missingMoveTo
}

/// SVG path 解析器。
public enum SVGPathParser {
    /// 解析 path 的 `d` 属性。
    /// - Parameter data: 例如 `"M4 12h16"`
    /// - Returns: 绘制路径(坐标单位与输入一致)
    /// - Throws: `SVGPathError`
    public static func parse(_ data: String) throws -> Path {
        var scanner = Scanner(Array(data))
        var path = Path()
        var current = CGPoint.zero
        var start = CGPoint.zero
        var lastCubicControl: CGPoint?
        var lastQuadControl: CGPoint?
        var command: Character?
        var hasMoveTo = false

        while true {
            scanner.skipSeparators()
            if scanner.atEnd { break }
            if let c = scanner.peek, c.isLetter {
                command = c
                scanner.advance()
                if c == "Z" || c == "z" {
                    path.closeSubpath()
                    current = start
                    lastCubicControl = nil
                    lastQuadControl = nil
                    continue
                }
            } else if command == nil {
                throw SVGPathError.unexpectedCharacter(scanner.peek ?? " ")
            }
            guard let cmd = command else { break }
            let relative = cmd.isLowercase
            let base = relative ? current : .zero
            switch cmd {
            case "M", "m":
                let p = try scanner.point(cmd, base: base)
                path.move(to: p)
                current = p
                start = p
                hasMoveTo = true
                command = relative ? "l" : "L"   // 后续坐标对隐式为 lineto
                lastCubicControl = nil
                lastQuadControl = nil
            case "L", "l":
                guard hasMoveTo else { throw SVGPathError.missingMoveTo }
                let p = try scanner.point(cmd, base: base)
                path.addLine(to: p)
                current = p
                lastCubicControl = nil
                lastQuadControl = nil
            case "H", "h":
                guard hasMoveTo else { throw SVGPathError.missingMoveTo }
                let x = try scanner.number(cmd)
                current = CGPoint(x: relative ? current.x + x : x, y: current.y)
                path.addLine(to: current)
                lastCubicControl = nil
                lastQuadControl = nil
            case "V", "v":
                guard hasMoveTo else { throw SVGPathError.missingMoveTo }
                let y = try scanner.number(cmd)
                current = CGPoint(x: current.x, y: relative ? current.y + y : y)
                path.addLine(to: current)
                lastCubicControl = nil
                lastQuadControl = nil
            case "C", "c":
                guard hasMoveTo else { throw SVGPathError.missingMoveTo }
                let c1 = try scanner.point(cmd, base: base)
                let c2 = try scanner.point(cmd, base: base)
                let p = try scanner.point(cmd, base: base)
                path.addCurve(to: p, control1: c1, control2: c2)
                current = p
                lastCubicControl = c2
                lastQuadControl = nil
            case "S", "s":
                guard hasMoveTo else { throw SVGPathError.missingMoveTo }
                let c1 = lastCubicControl.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                let c2 = try scanner.point(cmd, base: base)
                let p = try scanner.point(cmd, base: base)
                path.addCurve(to: p, control1: c1, control2: c2)
                current = p
                lastCubicControl = c2
                lastQuadControl = nil
            case "Q", "q":
                guard hasMoveTo else { throw SVGPathError.missingMoveTo }
                let c = try scanner.point(cmd, base: base)
                let p = try scanner.point(cmd, base: base)
                path.addQuadCurve(to: p, control: c)
                current = p
                lastQuadControl = c
                lastCubicControl = nil
            case "T", "t":
                guard hasMoveTo else { throw SVGPathError.missingMoveTo }
                let c = lastQuadControl.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                let p = try scanner.point(cmd, base: base)
                path.addQuadCurve(to: p, control: c)
                current = p
                lastQuadControl = c
                lastCubicControl = nil
            case "A", "a":
                guard hasMoveTo else { throw SVGPathError.missingMoveTo }
                let rx = try scanner.number(cmd)
                let ry = try scanner.number(cmd)
                let rotation = try scanner.number(cmd)
                let large = try scanner.flag()
                let sweep = try scanner.flag()
                let p = try scanner.point(cmd, base: base)
                addArc(&path, from: current, to: p, rx: rx, ry: ry, rotation: rotation, large: large, sweep: sweep)
                current = p
                lastCubicControl = nil
                lastQuadControl = nil
            default:
                throw SVGPathError.unexpectedCharacter(cmd)
            }
        }
        return path
    }

    /// 解析多段 path 并合并为一条路径。
    /// - Parameter dataList: 多个 `d` 字符串
    /// - Returns: 合并路径
    /// - Throws: `SVGPathError`
    public static func parse(all dataList: [String]) throws -> Path {
        var combined = Path()
        for data in dataList { combined.addPath(try parse(data)) }
        return combined
    }

    // MARK: - 圆弧

    /// 把 SVG 端点参数化的圆弧转换为若干三次贝塞尔曲线(W3C SVG 1.1 附录 F.6)。
    static func addArc(_ path: inout Path, from p0: CGPoint, to p1: CGPoint, rx rxIn: Double, ry ryIn: Double, rotation: Double, large: Bool, sweep: Bool) {
        var rx = abs(rxIn)
        var ry = abs(ryIn)
        if p0 == p1 { return }
        if rx == 0 || ry == 0 {
            path.addLine(to: p1)
            return
        }
        let phi = rotation * .pi / 180
        let cosPhi = cos(phi)
        let sinPhi = sin(phi)
        let dx = (Double(p0.x) - Double(p1.x)) / 2
        let dy = (Double(p0.y) - Double(p1.y)) / 2
        let x1p = cosPhi * dx + sinPhi * dy
        let y1p = -sinPhi * dx + cosPhi * dy
        // 半径过小时等比放大
        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 {
            let scale = sqrt(lambda)
            rx *= scale
            ry *= scale
        }
        let numerator = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
        let denominator = rx * rx * y1p * y1p + ry * ry * x1p * x1p
        var coefficient = denominator == 0 ? 0 : sqrt(max(0, numerator / denominator))
        if large == sweep { coefficient = -coefficient }
        let cxp = coefficient * (rx * y1p / ry)
        let cyp = coefficient * (-ry * x1p / rx)
        let cx = cosPhi * cxp - sinPhi * cyp + (Double(p0.x) + Double(p1.x)) / 2
        let cy = sinPhi * cxp + cosPhi * cyp + (Double(p0.y) + Double(p1.y)) / 2

        func angle(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
            let dot = ux * vx + uy * vy
            let len = sqrt(ux * ux + uy * uy) * sqrt(vx * vx + vy * vy)
            var a = acos(max(-1, min(1, dot / len)))
            if ux * vy - uy * vx < 0 { a = -a }
            return a
        }
        let theta1 = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
        var delta = angle((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
        if !sweep && delta > 0 { delta -= 2 * .pi }
        if sweep && delta < 0 { delta += 2 * .pi }

        let segments = max(1, Int(ceil(abs(delta) / (.pi / 2) - 1e-9)))
        let step = delta / Double(segments)
        let t = 4.0 / 3.0 * tan(step / 4)
        var angle1 = theta1
        for _ in 0..<segments {
            let angle2 = angle1 + step
            let cos1 = cos(angle1), sin1 = sin(angle1)
            let cos2 = cos(angle2), sin2 = sin(angle2)
            // 单位圆上的控制点,再缩放、旋转、平移
            func map(_ x: Double, _ y: Double) -> CGPoint {
                let px = x * rx
                let py = y * ry
                return CGPoint(x: cosPhi * px - sinPhi * py + cx, y: sinPhi * px + cosPhi * py + cy)
            }
            let c1 = map(cos1 - t * sin1, sin1 + t * cos1)
            let c2 = map(cos2 + t * sin2, sin2 - t * cos2)
            let end = angle2 == theta1 + delta ? p1 : map(cos2, sin2)
            path.addCurve(to: end, control1: c1, control2: c2)
            angle1 = angle2
        }
    }

    // MARK: - 词法

    /// 字符扫描器(处理 `1.5-2.9`、`.5.5`、`01` 紧凑标志位等省略分隔符的写法)。
    struct Scanner {
        let chars: [Character]
        var index = 0

        init(_ chars: [Character]) { self.chars = chars }

        var atEnd: Bool { index >= chars.count }
        var peek: Character? { index < chars.count ? chars[index] : nil }
        mutating func advance() { index += 1 }

        mutating func skipSeparators() {
            while let c = peek, c == " " || c == "," || c == "\n" || c == "\t" || c == "\r" { index += 1 }
        }

        mutating func number(_ command: Character) throws -> Double {
            skipSeparators()
            let begin = index
            if let c = peek, c == "+" || c == "-" { index += 1 }
            var sawDigit = false
            while let c = peek, c.isASCII, c.isNumber { index += 1; sawDigit = true }
            if peek == "." {
                index += 1
                while let c = peek, c.isASCII, c.isNumber { index += 1; sawDigit = true }
            }
            if sawDigit, let c = peek, c == "e" || c == "E" {
                var look = index + 1
                if look < chars.count, chars[look] == "+" || chars[look] == "-" { look += 1 }
                if look < chars.count, chars[look].isASCII, chars[look].isNumber {
                    index = look
                    while let d = peek, d.isASCII, d.isNumber { index += 1 }
                }
            }
            guard sawDigit, let value = Double(String(chars[begin..<index])) else { throw SVGPathError.missingNumber(command: command) }
            return value
        }

        mutating func flag() throws -> Bool {
            skipSeparators()
            guard let c = peek, c == "0" || c == "1" else { throw SVGPathError.invalidFlag }
            index += 1
            return c == "1"
        }

        mutating func point(_ command: Character, base: CGPoint) throws -> CGPoint {
            let x = try number(command)
            let y = try number(command)
            return CGPoint(x: base.x + x, y: base.y + y)
        }
    }
}
