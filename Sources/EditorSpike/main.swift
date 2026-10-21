// @author ixxxxoooo
// 编辑器性能测量工具(M0 起步,I1 扩展):装载文件,测量「打开到首个高亮帧」「滚动帧耗时」「按键到上屏延迟」「主线程卡顿」与内存。
// 用法(必须 release):
//   swift run -c release EditorSpike [--ide-big | --lines N | --file 路径] [--nowrap] [--keys N] [--scroll N] [--json]
// `--ide-big` 使用与 IDE 实验室 `Big50k.swift` 相同的 5 万行 / 约 1.6MB 素材(计划第 4 节的测量对象);默认 5 万行合成 Swift 源码、自动换行。`Scripts/editor-bench.sh` 会同时跑换行与不换行两种模式并按计划预算打印结论。

import AppKit
import DemoKit
import EditorKit
import OMLog

/// 生成指定行数的 Swift 风格代码。
func generateSource(lines: Int) -> String {
    var out = ""
    out.reserveCapacity(lines * 48)
    for i in 0..<lines {
        switch i % 5 {
        case 0: out += "func compute\(i)(value: Int) -> Int { // 注释 \(i)\n"
        case 1: out += "    let result = value * \(i) + \"字符串\\(i)\".count\n"
        case 2: out += "    if result > 10 { return result } else { return 0 }\n"
        case 3: out += "}\n"
        default: out += "\n"
        }
    }
    return out
}

/// 取分位数(0…1)。
func percentile(_ values: [Double], _ p: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    return sorted[min(Int(Double(sorted.count) * p), sorted.count - 1)]
}

func ms(_ duration: Duration) -> Double { duration.seconds * 1000 }

/// 命令行参数。
struct Options {
    var lines = 50_000
    var file: String?
    var nowrap = false
    var keys = 120
    var scrollSteps = 400
    var json = false
    var ideBig = false

    init(_ arguments: [String]) {
        var iterator = arguments.dropFirst().makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--lines": lines = Int(iterator.next() ?? "") ?? lines
            case "--file": file = iterator.next()
            case "--nowrap": nowrap = true
            case "--keys": keys = Int(iterator.next() ?? "") ?? keys
            case "--scroll": scrollSteps = Int(iterator.next() ?? "") ?? scrollSteps
            case "--json": json = true
            case "--ide-big": ideBig = true
            default: lines = Int(argument) ?? lines
            }
        }
    }
}

/// 当前进程 phys_footprint(MB)。
func footprintMB() -> Int {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return kr == KERN_SUCCESS ? Int(info.phys_footprint / 1024 / 1024) : -1
}

let options = Options(CommandLine.arguments)
// perf 日志写到 /tmp/oma-editor-spike/(编辑器内部的装载、视口高亮等耗时在其中)
Log.bootstrap(process: "editor-spike", directory: URL(fileURLWithPath: "/tmp/oma-editor-spike", isDirectory: true))
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let source: String
if let path = options.file {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { print("[editor] 无法读取 \(path)"); exit(2) }
    source = text
} else if options.ideBig {
    source = DemoIDELab.swiftLines(count: DemoIDELab.bigLineCount)
} else {
    source = generateSource(lines: options.lines)
}
let lineTotal = source.utf8.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
let baseline = footprintMB()
var results: [String: Double] = [:]
@MainActor func report(_ key: String, _ value: Double, _ unit: String = "ms") {
    results[key] = value
    if !options.json { print("[\(key)] \(String(format: "%.2f", value)) \(unit)") }
}
if !options.json { print("[editor] 文件: \(lineTotal) 行, \(source.utf8.count / 1024) KB, 模式: \(options.nowrap ? "不换行" : "自动换行")") }

let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
let editor = CodeEditorView(isEditable: true)
editor.wrapsLines = !options.nowrap
window.contentView = editor
window.orderFrontRegardless()

// 打开:装载并首屏上屏
let openStart = ContinuousClock.now
editor.setText(source, language: .swift)
window.displayIfNeeded()
report("open.first-frame", ms(ContinuousClock.now - openStart))
if !options.json { print("[editor] 大文件模式: \(editor.isLargeFileMode), 是否换行: \(editor.isWrapping)") }

// 打开到首个高亮帧:等待视口高亮应用(后台词法 + 主线程应用)
while editor.highlightedRange.length == 0, (ContinuousClock.now - openStart) < .seconds(10) {
    try? await Task.sleep(for: .milliseconds(2))
    window.displayIfNeeded()
}
report("open.first-highlight", ms(ContinuousClock.now - openStart))
try? await Task.sleep(for: .milliseconds(1200))
report("memory.after-open", Double(footprintMB() - baseline), "MB")

// 滚动:每步 600pt,度量每步布局 + 绘制耗时
var scrollTimes: [Double] = []
let clip = editor.scrollView.contentView
var y: CGFloat = 0
for _ in 0..<options.scrollSteps {
    y += 600
    // 每步一个自动释放池:真实滚动每个事件都会走完一次 RunLoop 并回收临时对象;
    // 同步循环不加池会把几百步的视图对象攒到下一次 await 才释放,造成假的数十毫秒停顿
    let step: Double = autoreleasepool {
        let start = ContinuousClock.now
        clip.scroll(to: NSPoint(x: 0, y: y))
        editor.scrollView.reflectScrolledClipView(clip)
        window.displayIfNeeded()
        return ms(ContinuousClock.now - start)
    }
    scrollTimes.append(step)
}
report("scroll.avg", scrollTimes.reduce(0, +) / Double(max(scrollTimes.count, 1)))
report("scroll.p95", percentile(scrollTimes, 0.95))
report("scroll.max", scrollTimes.max() ?? 0)
report("scroll.over-33ms", Double(scrollTimes.filter { $0 > 33 }.count), "步")

// 输入:在中部连续输入,键间隔 30ms,每 20 键停 300ms(让防抖后的后台重建与高亮回到主线程);
// 同时用睡眠唤醒的迟到量度量主线程被占用的最长时间
editor.scrollView.contentView.scroll(to: NSPoint(x: 0, y: editor.textView.frame.height / 2))
editor.scrollView.reflectScrolledClipView(editor.scrollView.contentView)
window.displayIfNeeded()
// 光标放在视口内(真实输入时光标总在可见区域;放在视口外会让系统为「滚动到光标」布局中间所有行,属于测量假象)
let caretOffset: Int = {
    guard let manager = editor.textView.textLayoutManager,
          let storage = manager.textContentManager as? NSTextContentStorage,
          let viewport = manager.textViewportLayoutController.viewportRange else { return (editor.textView.string as NSString).length / 2 }
    return storage.offset(from: storage.documentRange.location, to: viewport.location) + 200
}()
editor.textView.setSelectedRange(NSRange(location: caretOffset, length: 0))
window.displayIfNeeded()
// SPIKE_SAMPLE=1:输入阶段前先拉起系统 `sample` 采样本进程 3 秒(用来定位首个按键后的主线程停顿)
if ProcessInfo.processInfo.environment["SPIKE_SAMPLE"] != nil {
    let sampler = Process()
    sampler.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
    sampler.arguments = ["\(ProcessInfo.processInfo.processIdentifier)", ProcessInfo.processInfo.environment["SPIKE_SAMPLE"] ?? "3", "1", "-file", "/tmp/oma-spike-sample.txt"]
    try? sampler.run()
    try? await Task.sleep(for: .milliseconds(1200))
}
// SPIKE_REPEAT=N:重复 N 次「新建编辑器 → 装载 → 首个按键」,配合 SPIKE_SAMPLE 聚合多次首键停顿的栈
if let repeatText = ProcessInfo.processInfo.environment["SPIKE_REPEAT"], let repeats = Int(repeatText) {
    for round in 0..<repeats {
        let probe = CodeEditorView(isEditable: true)
        probe.wrapsLines = !options.nowrap
        window.contentView = probe
        probe.setText(source, language: .swift)
        window.displayIfNeeded()
        try? await Task.sleep(for: .milliseconds(400))
        // 先深度滚动,制造大量已缓存的布局片段,再在视口内输入
        let probeClip = probe.scrollView.contentView
        var probeY: CGFloat = 0
        for _ in 0..<options.scrollSteps {
            probeY += 600
            autoreleasepool {
                probeClip.scroll(to: NSPoint(x: 0, y: probeY))
                probe.scrollView.reflectScrolledClipView(probeClip)
                window.displayIfNeeded()
            }
        }
        if let manager = probe.textView.textLayoutManager, let storage = manager.textContentManager as? NSTextContentStorage,
           let viewport = manager.textViewportLayoutController.viewportRange {
            probe.textView.setSelectedRange(NSRange(location: storage.offset(from: storage.documentRange.location, to: viewport.location) + 200, length: 0))
        }
        let start = ContinuousClock.now
        probe.textView.insertText("x", replacementRange: probe.textView.selectedRange())
        window.displayIfNeeded()
        let keyMs = ms(ContinuousClock.now - start)
        let sleepStart = ContinuousClock.now
        try? await Task.sleep(for: .milliseconds(30))
        print("[repeat] 第 \(round + 1) 轮 首键 \(String(format: "%.1f", keyMs)) ms, 之后唤醒迟到 \(String(format: "%.1f", ms(ContinuousClock.now - sleepStart) - 30)) ms")
    }
    exit(0)
}
var typeTimes: [Double] = []
var worstStall = 0.0
for index in 0..<options.keys {
    let keyMs: Double = autoreleasepool {
        let start = ContinuousClock.now
        editor.textView.insertText("x", replacementRange: editor.textView.selectedRange())
        window.displayIfNeeded()
        return ms(ContinuousClock.now - start)
    }
    typeTimes.append(keyMs)
    let gap: Duration = (index + 1) % 20 == 0 ? .milliseconds(300) : .milliseconds(30)
    let sleepStart = ContinuousClock.now
    try? await Task.sleep(for: gap)
    let late = ms(ContinuousClock.now - sleepStart) - gap.seconds * 1000
    if late > 10, ProcessInfo.processInfo.environment["SPIKE_VERBOSE"] != nil { print("[stall] 第 \(index + 1) 键后唤醒迟到 \(String(format: "%.1f", late)) ms") }
    worstStall = max(worstStall, late)
}
report("typing.avg", typeTimes.reduce(0, +) / Double(max(typeTimes.count, 1)))
report("typing.p95", percentile(typeTimes, 0.95))
report("typing.max", typeTimes.max() ?? 0)
report("typing.main-stall-max", worstStall)
report("memory.final", Double(footprintMB() - baseline), "MB")

if options.json {
    let data = try? JSONSerialization.data(withJSONObject: results, options: [.sortedKeys])
    print(String(data: data ?? Data(), encoding: .utf8) ?? "{}")
}
exit(0)
