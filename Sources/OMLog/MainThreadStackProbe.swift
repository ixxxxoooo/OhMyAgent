// @author ixxxxoooo
// 主线程调用栈探针:在任意后台线程「挂起主线程 → 读寄存器 → 沿帧指针回溯 → 恢复」,
// 全程不分配内存、不加锁,挂起窗口只有几微秒;符号化延迟到恢复之后(见 `StackSymbolizer`)。
// 取代原先「调用 /usr/bin/sample」的方案:不再受 100~300ms 的进程启动延迟与 dyld 锁争用影响,
// 并且能在一次卡顿的全程里连续采样(而不只是 1 秒)。

import Darwin
import Foundation

/// 主线程调用栈探针。必须在主线程创建(记录主线程的 Mach 端口与栈边界)。
public final class MainThreadStackProbe: @unchecked Sendable {
    /// 主线程 Mach 端口
    private let thread: mach_port_t
    /// 主线程栈的低/高地址(用于校验帧指针,避免读到非法内存)
    private let stackLow: UInt
    private let stackHigh: UInt

    /// 在**当前线程**(必须是主线程)上创建探针;非主线程调用返回 nil。
    public init?() {
        guard Thread.isMainThread else { return nil }
        let current = pthread_self()
        let high = UInt(bitPattern: pthread_get_stackaddr_np(current))
        let size = UInt(pthread_get_stacksize_np(current))
        guard high > size, size > 0 else { return nil }
        self.thread = mach_thread_self()
        self.stackHigh = high
        self.stackLow = high - size
    }

    /// 采集一次主线程栈。
    /// - Parameters:
    ///   - buffer: 调用方预分配的地址缓冲(挂起期间不得分配内存)
    ///   - capacity: 缓冲容量(帧数)
    /// - Returns: 写入的帧数(从栈顶到栈底);失败为 0
    public func capture(into buffer: UnsafeMutablePointer<UInt>, capacity: Int) -> Int {
        #if arch(arm64)
        guard capacity > 0, thread_suspend(thread) == KERN_SUCCESS else { return 0 }
        var state = arm_thread_state64_t()
        var count = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<UInt32>.size)
        let status = withUnsafeMutablePointer(to: &state) { pointer in
            pointer.withMemoryRebound(to: natural_t.self, capacity: Int(count)) { raw in
                thread_get_state(thread, ARM_THREAD_STATE64, raw, &count)
            }
        }
        var written = 0
        if status == KERN_SUCCESS {
            // 去掉指针认证位,只保留 48 位虚拟地址
            let mask: UInt = 0x0000_FFFF_FFFF_FFFF
            let pc = UInt(state.__pc) & mask
            let lr = UInt(state.__lr) & mask
            var frame = UInt(state.__fp) & mask
            let sp = UInt(state.__sp) & mask
            buffer[written] = pc
            written += 1
            // 叶子函数可能还没把 lr 压栈:先记录 lr 作为调用者
            if lr != 0, written < capacity {
                buffer[written] = lr
                written += 1
            }
            while written < capacity {
                // 帧必须 16 字节对齐、落在主线程栈内且高于当前 sp
                guard frame & 0xF == 0, frame >= max(sp, stackLow), frame + 16 <= stackHigh,
                      let base = UnsafePointer<UInt>(bitPattern: frame) else { break }
                let next = base[0] & mask
                let returnAddress = base[1] & mask
                guard returnAddress != 0 else { break }
                buffer[written] = returnAddress
                written += 1
                guard next > frame else { break }
                frame = next
            }
        }
        thread_resume(thread)
        return written
        #else
        return 0
        #endif
    }
}

/// 栈帧符号化(在探针恢复主线程之后调用,可以随意分配内存)。
public enum StackSymbolizer {
    /// `swift_demangle` 的 C 函数签名。
    private typealias DemangleFunction = @convention(c) (
        UnsafePointer<CChar>?, UInt, UnsafeMutablePointer<CChar>?, UnsafeMutablePointer<UInt>?, UInt32
    ) -> UnsafeMutablePointer<CChar>?

    /// 运行时解析 Swift 符号还原函数(解析不到时不还原)。
    private static let demangleFunction: DemangleFunction? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "swift_demangle") else { return nil }
        return unsafeBitCast(symbol, to: DemangleFunction.self)
    }()

    /// 把一个返回地址描述成可读文本:`符号 (in 模块) +偏移`;无符号时退化为 `模块 +偏移`,便于事后用 atos 还原。
    /// - Parameter address: 指令地址
    /// - Returns: 帧描述
    public static func describe(_ address: UInt) -> String {
        guard let pointer = UnsafeRawPointer(bitPattern: address) else { return "0x0" }
        var info = Dl_info()
        guard dladdr(pointer, &info) != 0 else { return "0x" + String(address, radix: 16) }
        let module = info.dli_fname.map { ($0.string as NSString).lastPathComponent } ?? "?"
        let base = UInt(bitPattern: info.dli_fbase)
        guard let rawName = info.dli_sname else {
            return "\(module) +0x" + String(address &- base, radix: 16)
        }
        let symbolStart = UInt(bitPattern: info.dli_saddr)
        let offset = address &- symbolStart
        return "\(demangle(rawName.string)) (in \(module)) +\(offset)"
    }

    /// 还原 Swift 符号名;非 Swift 符号原样返回,过长则截断。
    static func demangle(_ mangled: String) -> String {
        var result = mangled
        if mangled.hasPrefix("$s") || mangled.hasPrefix("_$s") || mangled.hasPrefix("$S") {
            result = mangled.withCString { cString -> String in
                guard let function = demangleFunction,
                      let demangled = function(cString, UInt(strlen(cString)), nil, nil, 0) else { return mangled }
                defer { free(demangled) }
                return String(cString: demangled)
            }
        }
        return result.count > 180 ? String(result.prefix(180)) + "…" : result
    }
}

private extension UnsafePointer where Pointee == CChar {
    /// C 字符串转 Swift 字符串。
    var string: String { String(cString: self) }
}
