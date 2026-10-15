// @author ygw
// pie 与 gantt:解析 + 布局。

import CoreGraphics
import Foundation

struct PieModel: Equatable {
    var title = ""
    var showData = false
    var slices: [(label: String, value: Double)] = []
    static func == (a: PieModel, b: PieModel) -> Bool {
        a.title == b.title && a.showData == b.showData && a.slices.elementsEqual(b.slices, by: { $0.label == $1.label && $0.value == $1.value })
    }
}

enum PieParser {
    static func parse(_ lines: [String]) throws -> PieModel {
        var model = PieModel()
        let entry = try NSRegularExpression(pattern: #"^"?([^"]+?)"?\s*:\s*(-?[0-9]+(?:\.[0-9]+)?)\s*$"#)
        for (idx, raw) in lines.enumerated() {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("%%") { continue }
            if idx == 0 {
                var rest = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                if rest.hasPrefix("showData") { model.showData = true; rest = String(rest.dropFirst(8)).trimmingCharacters(in: .whitespaces) }
                if rest.hasPrefix("title") { model.title = String(rest.dropFirst(5)).trimmingCharacters(in: .whitespaces) }
                continue
            }
            if line.hasPrefix("title") { model.title = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces); continue }
            if line == "showData" { model.showData = true; continue }
            line = line.trimmingCharacters(in: .whitespaces)
            let ns = line as NSString
            guard let m = entry.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
                  let value = Double(ns.substring(with: m.range(at: 2))) else {
                throw MermaidError(line: idx + 1, "饼图条目格式应为 \"名称\" : 数值")
            }
            guard value >= 0 else { throw MermaidError(line: idx + 1, "饼图数值不能为负") }
            model.slices.append((ns.substring(with: m.range(at: 1)), value))
        }
        guard !model.slices.isEmpty else { throw MermaidError("饼图没有数据") }
        return model
    }
}

enum PieLayout {
    static func scene(for model: PieModel) -> MScene {
        let total = model.slices.reduce(0) { $0 + $1.value }
        let radius = 110.0
        let top = model.title.isEmpty ? 20.0 : 56.0
        let center = CGPoint(x: 20 + radius, y: top + radius)
        var items: [MItem] = []
        if !model.title.isEmpty {
            items.append(.text(model.title, at: CGPoint(x: center.x, y: 26), anchor: .center, size: 15, bold: true, color: .text, background: false))
        }
        var angle = 0.0
        for (i, s) in model.slices.enumerated() where total > 0 {
            let sweep = s.value / total * 2 * .pi
            if sweep > 0 { items.append(.slice(center: center, radius: radius, from: angle, to: angle + sweep, color: .accent(i))) }
            if s.value / total >= 0.06 {
                let mid = angle + sweep / 2
                let p = CGPoint(x: center.x + sin(mid) * radius * 0.68, y: center.y - cos(mid) * radius * 0.68)
                items.append(.text(String(format: "%.0f%%", s.value / total * 100), at: p, anchor: .center, size: 12, bold: true, color: .text, background: false))
            }
            angle += sweep
        }
        // 图例
        let legendX = center.x + radius + 36
        var legendWidth = 0.0
        for (i, s) in model.slices.enumerated() {
            let y = top + 14 + Double(i) * 24
            let text = model.showData ? "\(s.label) [\(trim(s.value))]" : s.label
            items.append(.rect(CGRect(x: legendX, y: y - 7, width: 14, height: 14), fill: .accent(i), stroke: nil, radius: 3, dashed: false))
            items.append(.text(text, at: CGPoint(x: legendX + 22, y: y), anchor: .leading, size: 12.5, bold: false, color: .text, background: false))
            legendWidth = max(legendWidth, MermaidMetrics.width(text, size: 12.5) + 22)
        }
        let height = max(top + radius * 2 + 20, top + 14 + Double(model.slices.count) * 24 + 10)
        return MScene(size: CGSize(width: legendX + legendWidth + 24, height: height), items: items)
    }

    static func trim(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%.2f", v) }
}

// MARK: - Gantt

struct GanttTask: Equatable {
    var title: String
    var id: String?
    var section: Int
    var start: Int      // 自 1970-01-01 起的天数
    var end: Int
    var crit = false, done = false, active = false, milestone = false
}

struct GanttModel: Equatable {
    var title = ""
    var sections: [String] = []
    var tasks: [GanttTask] = []
}

enum GanttParser {
    private static func days(_ s: String) -> Int? {
        let parts = s.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        guard let date = c.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else { return nil }
        return Int((date.timeIntervalSince1970 / 86400).rounded(.down))
    }

    private static func duration(_ s: String) -> Int? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard let unit = t.last, let n = Double(t.dropLast()) else { return nil }
        switch unit {
        case "d": return max(Int(n.rounded(.up)), 0)
        case "w": return Int(n * 7)
        case "h": return max(Int((n / 24).rounded(.up)), 1)
        case "m": return max(Int((n / 1440).rounded(.up)), 1)
        case "M": return Int(n * 30)
        default: return nil
        }
    }

    static func parse(_ lines: [String]) throws -> GanttModel {
        var model = GanttModel()
        var section = -1
        var lastEnd: Int?
        var byID: [String: GanttTask] = [:]
        let keywords: Set<String> = ["crit", "done", "active", "milestone"]
        for (idx, raw) in lines.enumerated() where idx > 0 {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("%%") { continue }
            let lower = line.lowercased()
            if lower.hasPrefix("title") { model.title = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces); continue }
            if ["dateformat", "axisformat", "tickinterval", "excludes", "includes", "todaymarker", "weekday", "weekend", "click"].contains(where: { lower.hasPrefix($0) }) { continue }
            if lower.hasPrefix("section") {
                model.sections.append(String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces)); section = model.sections.count - 1; continue
            }
            guard let colon = line.lastIndex(of: ":") else { throw MermaidError(line: idx + 1, "甘特图任务应为 名称 : 日期信息") }
            let title = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let fields = line[line.index(after: colon)...].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            var task = GanttTask(title: title, id: nil, section: max(section, 0), start: 0, end: 0)
            var rest: [String] = []
            for f in fields {
                if keywords.contains(f) {
                    switch f { case "crit": task.crit = true; case "done": task.done = true; case "active": task.active = true; default: task.milestone = true }
                } else { rest.append(f) }
            }
            // 剩余:[id,] [start,] end|duration
            if rest.count >= 2, days(rest[0]) == nil, !rest[0].hasPrefix("after "), duration(rest[0]) == nil { task.id = rest.removeFirst() }
            var start: Int?
            var end: Int?
            if rest.count >= 2 {
                let s = rest[0]
                if s.hasPrefix("after ") { start = byID[String(s.dropFirst(6)).trimmingCharacters(in: .whitespaces)]?.end }
                else { start = days(s) }
                let e = rest[1]
                if let d = days(e) { end = d } else if let n = duration(e), let st = start ?? lastEnd { start = st; end = st + n }
            } else if rest.count == 1 {
                let e = rest[0]
                start = lastEnd
                if let d = days(e) { end = d } else if let n = duration(e), let st = lastEnd { end = st + n }
            }
            guard let st = start ?? lastEnd, let en = end else { throw MermaidError(line: idx + 1, "无法解析任务日期:\(line.prefix(30))") }
            task.start = st
            task.end = task.milestone ? st : max(en, st)
            lastEnd = task.end
            if let id = task.id { byID[id] = task }
            model.tasks.append(task)
        }
        guard !model.tasks.isEmpty else { throw MermaidError("甘特图没有任务") }
        if model.sections.isEmpty { model.sections = [""] }
        return model
    }
}

enum GanttLayout {
    static func scene(for model: GanttModel) -> MScene {
        let minDay = model.tasks.map(\.start).min() ?? 0
        let maxDay = max(model.tasks.map(\.end).max() ?? 1, minDay + 1)
        let span = Double(maxDay - minDay)
        let nameWidth = min(max(model.tasks.map { MermaidMetrics.width($0.title, size: 12) }.max() ?? 80, 80) + 24, 240)
        let chartWidth = 560.0
        let rowH = 28.0, headerH = 34.0
        let left = 20.0, top = model.title.isEmpty ? 16.0 : 46.0
        let chartX = left + nameWidth
        func x(_ day: Int) -> Double { chartX + Double(day - minDay) / span * chartWidth }

        var items: [MItem] = []
        if !model.title.isEmpty {
            items.append(.text(model.title, at: CGPoint(x: chartX + chartWidth / 2, y: 24), anchor: .center, size: 15, bold: true, color: .text, background: false))
        }
        // 行布局
        var y = top + headerH
        var rows: [(Int?, GanttTask?)] = []
        for s in model.sections.indices {
            let ts = model.tasks.filter { $0.section == s }
            if ts.isEmpty { continue }
            if !model.sections[s].isEmpty { rows.append((s, nil)) }
            for t in ts { rows.append((nil, t)) }
        }
        let bottom = y + Double(rows.count) * rowH
        // 刻度
        let step = span <= 16 ? 1 : (span <= 70 ? 7 : max(Int(span / 8), 1))
        var tick = minDay
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        while tick <= maxDay {
            let px = x(tick)
            items.append(.line(CGPoint(x: px, y: top + headerH - 6), CGPoint(x: px, y: bottom), style: .dashed, color: .groupStroke))
            let date = Date(timeIntervalSince1970: Double(tick) * 86400)
            let comps = c.dateComponents([.month, .day], from: date)
            items.append(.text(String(format: "%02d-%02d", comps.month ?? 0, comps.day ?? 0), at: CGPoint(x: px, y: top + 12), anchor: .center, size: 11, bold: false, color: .subtleText, background: false))
            tick += step
        }
        for (secIdx, task) in rows {
            if let secIdx {
                items.append(.rect(CGRect(x: left, y: y, width: nameWidth + chartWidth, height: rowH), fill: .groupFill, stroke: nil, radius: 0, dashed: false))
                items.append(.text(model.sections[secIdx], at: CGPoint(x: left + 8, y: y + rowH / 2), anchor: .leading, size: 12, bold: true, color: .text, background: false))
            } else if let task {
                items.append(.text(task.title, at: CGPoint(x: left + 12, y: y + rowH / 2), anchor: .leading, size: 12, bold: false, color: .text, background: false))
                let color: MColor = task.crit ? .danger : (task.done ? .subtleText : (task.active ? .accent(0) : .accent(task.section + 1)))
                if task.milestone {
                    let r = CGRect(x: x(task.start) - 8, y: y + rowH / 2 - 8, width: 16, height: 16)
                    items.append(.shape(.diamond, rect: r, text: "", fill: color, stroke: color))
                } else {
                    let w = max(x(task.end) - x(task.start), 4)
                    items.append(.rect(CGRect(x: x(task.start), y: y + 5, width: w, height: rowH - 10), fill: color, stroke: nil, radius: 4, dashed: false))
                }
            }
            y += rowH
        }
        return MScene(size: CGSize(width: chartX + chartWidth + 28, height: bottom + 20), items: items)
    }
}
