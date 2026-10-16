// @author ixxxxoooo
// M0 Spike C:TextKit 2 打开 5 万行文件,测量装载、首屏布局、滚动与输入耗时。

import AppKit
import EditorKit

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

func percentile(_ values: [Double], _ p: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    return sorted[min(Int(Double(sorted.count) * p), sorted.count - 1)]
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let lineCount = Int(CommandLine.arguments.dropFirst().first ?? "50000") ?? 50_000
let source = generateSource(lines: lineCount)
print("[editor] 文件: \(lineCount) 行, \(source.utf8.count / 1024) KB")

let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
let editor = CodeEditorView(isEditable: true)
window.contentView = editor
window.orderFrontRegardless()

let t0 = ContinuousClock.now
editor.setText(source, language: .swift)
window.displayIfNeeded()
print("[editor] 装载并首屏布局: \(String(format: "%.1f", (ContinuousClock.now - t0).seconds * 1000)) ms (setText 内部 \(String(format: "%.1f", editor.lastLoadDuration * 1000)) ms)")
print("[editor] 大文件模式: \(editor.isLargeFileMode)")

// 等待后台索引与高亮完成
try? await Task.sleep(for: .milliseconds(1500))
print("[editor] 大文件模式(精确行数): \(editor.isLargeFileMode)")

// 滚动:每步 600pt,共 400 步,度量每步布局+绘制耗时
var scrollTimes: [Double] = []
let clip = editor.scrollView.contentView
var y: CGFloat = 0
for _ in 0..<400 {
    y += 600
    let s = ContinuousClock.now
    clip.scroll(to: NSPoint(x: 0, y: y))
    editor.scrollView.reflectScrolledClipView(clip)
    window.displayIfNeeded()
    scrollTimes.append((ContinuousClock.now - s).seconds * 1000)
}
print("[scroll] 400 步: avg \(String(format: "%.2f", scrollTimes.reduce(0, +) / Double(scrollTimes.count))) ms, p95 \(String(format: "%.2f", percentile(scrollTimes, 0.95))) ms, max \(String(format: "%.2f", scrollTimes.max() ?? 0)) ms")
let over8 = scrollTimes.filter { $0 > 8.33 }.count
let over16 = scrollTimes.filter { $0 > 16.67 }.count
print("[scroll] 超过 8.33ms(120Hz 预算): \(over8) 步, 超过 16.67ms(60Hz 预算): \(over16) 步")

// 输入:在中部插入字符 100 次
editor.textView.setSelectedRange(NSRange(location: source.utf16.count / 2, length: 0))
var typeTimes: [Double] = []
for _ in 0..<100 {
    let s = ContinuousClock.now
    editor.textView.insertText("x", replacementRange: editor.textView.selectedRange())
    window.displayIfNeeded()
    typeTimes.append((ContinuousClock.now - s).seconds * 1000)
}
print("[typing] 100 次: avg \(String(format: "%.2f", typeTimes.reduce(0, +) / Double(typeTimes.count))) ms, p95 \(String(format: "%.2f", percentile(typeTimes, 0.95))) ms, max \(String(format: "%.2f", typeTimes.max() ?? 0)) ms")

var info = task_vm_info_data_t()
var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
let kr = withUnsafeMutablePointer(to: &info) {
    $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
}
if kr == KERN_SUCCESS { print("[memory] phys_footprint: \(info.phys_footprint / 1024 / 1024) MB") }
exit(0)
