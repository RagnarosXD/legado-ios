//
//  CrashReporter.swift
//  Legado-iOS
//
//  崩溃捕获（写进同一个主日志 Documents/Logs/legado.log）
//
//  设计约束：信号处理里**绝不能**调用 Swift 运行时 / Foundation / 分配内存，
//  否则会在信号上下文死锁，进程被系统强杀，连日志都写不出来。
//  因此所有字符串与缓冲区都在 install() 时预先生成（C 语义），
//  信号里只做：write() + backtrace() + backtrace_symbols_fd() + fsync()。
//

import Foundation
import UIKit

enum CrashReporter {

    private static var installed = false
    private static let launchFlagKey = "legado.lastLaunchFinished"

    /// 主日志 fd（O_APPEND），install 时预打开
    private static var logFileDescriptor: Int32 = -1

    // MARK: - 预分配缓冲（信号上下文只读，不分配）

    private static var headerCString: UnsafeMutablePointer<CChar>?
    private static var midCString: UnsafeMutablePointer<CChar>?
    private static var tailCString: UnsafeMutablePointer<CChar>?

    private static var nameABRTCString: UnsafeMutablePointer<CChar>?
    private static var nameSEGVCString: UnsafeMutablePointer<CChar>?
    private static var nameBUSCString: UnsafeMutablePointer<CChar>?
    private static var nameILLCString: UnsafeMutablePointer<CChar>?
    private static var nameFPECString: UnsafeMutablePointer<CChar>?
    private static var nameTRAPCString: UnsafeMutablePointer<CChar>?

    /// 主线程 pthread（install 时保存），用于卡顿时发 SIGPROF 采样
    private static var mainThreadHandle: pthread_t?
    private static var profHeaderCString: UnsafeMutablePointer<CChar>?
    private static let profMaxFrames = 64
    private static var profFrames: UnsafeMutablePointer<UnsafeMutableRawPointer?> = {
        let pointer = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: profMaxFrames)
        pointer.initialize(repeating: nil, count: profMaxFrames)
        return pointer
    }()

    private static let maxFrames = 96
    /// 预分配的回溯缓冲区（信号里不能 malloc）
    private static var framesBuffer: UnsafeMutablePointer<UnsafeMutableRawPointer?> = {
        let pointer = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: maxFrames)
        pointer.initialize(repeating: nil, count: maxFrames)
        return pointer
    }()

    // MARK: - 安装

    static func install() {
        guard !installed else { return }
        installed = true

        // 上次是否走到「正常进入前台」——没走到就当异常退出
        if UserDefaults.standard.bool(forKey: launchFlagKey) {
            // 被 SIGKILL（watchdog / OOM / 手动划掉）时信号处理不会执行，
            // 靠这个小文件告诉用户「上次最后一步在做什么」
            let lastState = ProgressRecorder.lastState() ?? "未知"
            AppLogger.warn("Crash", "检测到上次未正常退出，最后状态：\(lastState)")
        }
        ProgressRecorder.clear()

        // 旧版散落的 crash-*.log 合并进主日志（空文件直接删除）
        AppLogger.shared.mergeLegacyCrashReports()

        logFileDescriptor = AppLogger.openAppendDescriptor()

        prepareSignalBuffers()

        // ObjC 异常：不是信号上下文，可以正常用 Swift
        NSSetUncaughtExceptionHandler { exception in
            CrashReporter.appendExceptionReport(exception)
        }

        let signals: [Int32] = [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP]
        for sig in signals {
            signal(sig) { received in
                CrashReporter.writeSignalSnapshot(received)
                signal(received, SIG_DFL)
                raise(received)
            }
        }

        // 主线程卡顿采样：看门狗对主线程发 SIGPROF，handler 里抓的正是主线程的栈。
        // SIGPROF 默认行为是终止进程，这里必须覆盖。
        mainThreadHandle = pthread_self()
        profHeaderCString = strdup("\n===== 主线程卡顿栈（SIGPROF 采样）=====\n--- backtrace ---\n")
        signal(SIGPROF) { _ in
            CrashReporter.writeProfSnapshot()
        }

        // 标脏：正常进入前台后由 markLaunchFinished 置为 false
        UserDefaults.standard.set(true, forKey: launchFlagKey)
    }

    /// 在 install() 阶段把所有字符串与缓冲区准备好（此时可以安全分配）
    private static func prepareSignalBuffers() {
        let version = AppLogger.appVersion
        headerCString = strdup("\n===== 崩溃（signal backtrace）=====\nversion: \(version)\nsignal: ")
        midCString = strdup("\n--- backtrace ---\n")
        tailCString = strdup("===== backtrace 结束 =====\n")

        nameABRTCString = strdup("SIGABRT —— 断言失败 / Swift 数组越界 / force unwrap nil / ObjC 异常")
        nameSEGVCString = strdup("SIGSEGV —— 访问非法内存")
        nameBUSCString = strdup("SIGBUS —— 内存对齐或映射错误")
        nameILLCString = strdup("SIGILL —— 非法指令")
        nameFPECString = strdup("SIGFPE —— 算术异常")
        nameTRAPCString = strdup("SIGTRAP —— 断点 / Swift 运行时 trap")
    }

    /// SIGPROF 处理体（必须是静态方法：signal 的 C 函数指针不能捕获上下文）
    private static func writeProfSnapshot() {
        let fd = logFileDescriptor
        guard fd >= 0 else { return }

        writeCString(profHeaderCString, to: fd)

        let count = backtrace(profFrames, Int32(profMaxFrames))
        if count > 0 {
            backtrace_symbols_fd(profFrames, count, fd)
        }

        writeCString(tailCString, to: fd)
        fsync(fd)
    }

    /// 让看门狗在主线程卡住时调用：给主线程发 SIGPROF，抓它当前的调用栈
    static func sampleMainThreadStack() {
        guard let thread = mainThreadHandle else { return }
        pthread_kill(thread, SIGPROF)
    }

    /// App 正常进入前台后调用：下次启动就不会误报「异常退出」
    static func markLaunchFinished() {
        UserDefaults.standard.set(false, forKey: launchFlagKey)
    }

    // MARK: - 信号快照（只做 C 语义操作）

    private static func writeSignalSnapshot(_ sig: Int32) {
        let fd = logFileDescriptor
        guard fd >= 0 else { return }

        writeCString(headerCString, to: fd)

        switch sig {
        case SIGABRT: writeCString(nameABRTCString, to: fd)
        case SIGSEGV: writeCString(nameSEGVCString, to: fd)
        case SIGBUS:  writeCString(nameBUSCString, to: fd)
        case SIGILL:  writeCString(nameILLCString, to: fd)
        case SIGFPE:  writeCString(nameFPECString, to: fd)
        case SIGTRAP: writeCString(nameTRAPCString, to: fd)
        default: break
        }

        writeCString(midCString, to: fd)

        let count = backtrace(framesBuffer, Int32(maxFrames))
        if count > 0 {
            backtrace_symbols_fd(framesBuffer, count, fd)
        }

        writeCString(tailCString, to: fd)
        fsync(fd)
    }

    /// 写入预分配的 C 字符串（信号安全：只调 write/strlen）
    private static func writeCString(_ pointer: UnsafeMutablePointer<CChar>?, to fd: Int32) {
        guard let pointer else { return }
        let length = strlen(pointer)
        guard length > 0 else { return }

        var written = 0
        while written < length {
            let result = write(fd, pointer.advanced(by: written), length - written)
            if result <= 0 { break }
            written += result
        }
    }

    // MARK: - NSException（普通上下文，可用 Swift）

    private static func appendExceptionReport(_ exception: NSException) {
        var lines: [String] = []
        lines.append("")
        lines.append("===== 崩溃（NSException）=====")
        lines.append("name: \(exception.name.rawValue)")
        lines.append("reason: \(exception.reason ?? "-")")
        lines.append("version: \(AppLogger.appVersion)")
        lines.append("system: \(UIDevice.current.systemName) \(UIDevice.current.systemVersion) / \(UIDevice.current.model)")
        lines.append("time: \(Date())")
        lines.append("--- call stack ---")
        lines.append(contentsOf: exception.callStackSymbols)
        lines.append("--- 最近日志 ---")
        lines.append(contentsOf: AppLogger.shared.recentLinesSnapshot(limit: 120))
        lines.append("===== 崩溃结束 =====")
        lines.append("")

        appendText(lines.joined(separator: "\n") + "\n")
    }

    /// 兼容旧 API
    static func writeReport(kind: String, detail: String, callStack: [String]) {
        var lines: [String] = []
        lines.append("")
        lines.append("===== 崩溃（\(kind)）=====")
        lines.append("detail: \(detail)")
        lines.append("version: \(AppLogger.appVersion)")
        if !callStack.isEmpty {
            lines.append("--- call stack ---")
            lines.append(contentsOf: callStack)
        }
        lines.append("--- 最近日志 ---")
        lines.append(contentsOf: AppLogger.shared.recentLinesSnapshot(limit: 120))
        lines.append("===== 崩溃结束 =====")
        lines.append("")

        appendText(lines.joined(separator: "\n") + "\n")
    }

    /// 直接追加到主日志（崩溃上下文里不依赖 AppLogger 的锁）
    private static func appendText(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }

        let path = AppLogger.directory.appendingPathComponent(AppLogger.activeFileName).path
        path.withCString { pointer in
            let fd = open(pointer, O_WRONLY | O_CREAT | O_APPEND, 0o644)
            guard fd >= 0 else { return }

            data.withUnsafeBytes { buffer in
                guard let base = buffer.baseAddress else { return }
                var written = 0
                while written < buffer.count {
                    let result = write(fd, base.advanced(by: written), buffer.count - written)
                    if result <= 0 { break }
                    written += result
                }
            }

            fsync(fd)
            close(fd)
        }
    }
}
