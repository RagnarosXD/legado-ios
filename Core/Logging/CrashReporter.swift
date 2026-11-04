//
//  CrashReporter.swift
//  Legado-iOS
//
//  崩溃捕获（全部写进同一个主日志 Documents/Logs/legado.log）：
//  - ObjC 异常（NSException）：记录 name / reason / callStackSymbols / 最近日志
//  - 信号（SIGABRT / SIGSEGV / SIGBUS / SIGILL / SIGFPE / SIGTRAP）：只用
//    async-signal-safe 的 write + backtrace_symbols_fd 追加 backtrace
//  - 不再每次启动预创建 crash-*.log（旧版那种空文件会导致真正的崩溃报告被覆盖）
//  - 启动时把旧版遗留的 crash-*.log 合并进主日志后删除
//

import Foundation
import Darwin
import UIKit

enum CrashReporter {

    private static var installed = false
    private static let launchFlagKey = "legado.lastLaunchFinished"

    /// 预先打开的主日志 fd（O_APPEND），供信号上下文安全使用
    private static var logFileDescriptor: Int32 = -1

    // MARK: - 安装

    static func install() {
        guard !installed else { return }
        installed = true

        let previousLaunchFinished = UserDefaults.standard.bool(forKey: launchFlagKey)
        if previousLaunchFinished == false {
            AppLogger.warn("Crash", "检测到上次未正常退出（watchdog / OOM 或被手动强杀都不会有 backtrace）")
        }
        UserDefaults.standard.set(false, forKey: launchFlagKey)

        // 旧版散落的 crash-*.log 合并进主日志（空文件直接删除）
        AppLogger.shared.mergeLegacyCrashReports()

        // 预打开主日志：信号处理里不能再 open / 做 FileManager 操作
        logFileDescriptor = AppLogger.openAppendDescriptor()

        // ObjC 异常（SwiftSoup / Core Data / UIKit 抛的 NSException 会走这里）
        NSSetUncaughtExceptionHandler { exception in
            CrashReporter.appendExceptionReport(exception)
        }

        // 信号：只用 async-signal-safe 的 write + backtrace_symbols_fd
        let signals: [Int32] = [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP]
        for sig in signals {
            signal(sig) { received in
                CrashReporter.writeSignalSnapshot(received)
                // 恢复默认处理并重新抛出，保留系统崩溃日志
                signal(received, SIG_DFL)
                raise(received)
            }
        }
    }

    /// App 正常进入前台后标记一次，用来判断下次启动是否为异常退出
    static func markLaunchFinished() {
        UserDefaults.standard.set(true, forKey: launchFlagKey)
    }

    // MARK: - NSException

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

        // 崩溃上下文里不依赖 FileHandle 的锁，直接 open + write
        let path = AppLogger.directory.appendingPathComponent(AppLogger.activeFileName).path
        path.withCString { pointer in
            let fd = open(pointer, O_WRONLY | O_CREAT | O_APPEND, 0o644)
            guard fd >= 0 else { return }
            writeText(lines.joined(separator: "\n") + "\n", to: fd)
            fsync(fd)
            close(fd)
        }
    }

    // MARK: - 信号快照（async-signal-safe）

    private static func writeSignalSnapshot(_ sig: Int32) {
        let fd = logFileDescriptor
        guard fd >= 0 else { return }

        writeCString("\n===== 崩溃（signal backtrace）=====\n", to: fd)
        writeCString(signalName(sig), to: fd)
        writeCString("\n", to: fd)
        writeCString("version: ", to: fd)
        writeCString(AppLogger.appVersion, to: fd)
        writeCString("\n--- backtrace ---\n", to: fd)

        // backtrace + backtrace_symbols_fd 是 async-signal-safe 的，不依赖 Swift/Foundation
        var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 96)
        let count = backtrace(&frames, 96)
        if count > 0 {
            backtrace_symbols_fd(&frames, count, fd)
        }

        writeCString("===== backtrace 结束 =====\n", to: fd)
        fsync(fd)
    }

    private static func writeCString(_ text: String, to fd: Int32) {
        text.withCString { pointer in
            _ = write(fd, pointer, strlen(pointer))
        }
    }

    private static func writeText(_ text: String, to fd: Int32) {
        guard let data = text.data(using: .utf8) else { return }
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var written = 0
            while written < buffer.count {
                let result = write(fd, base.advanced(by: written), buffer.count - written)
                if result <= 0 { break }
                written += result
            }
        }
    }

    // MARK: - 兼容旧 API

    /// 保留给其它调用方：直接把一段报告追加进主日志
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

        let path = AppLogger.directory.appendingPathComponent(AppLogger.activeFileName).path
        path.withCString { pointer in
            let fd = open(pointer, O_WRONLY | O_CREAT | O_APPEND, 0o644)
            guard fd >= 0 else { return }
            writeText(lines.joined(separator: "\n") + "\n", to: fd)
            fsync(fd)
            close(fd)
        }
    }

    // MARK: - 工具

    private static func signalName(_ sig: Int32) -> String {
        switch sig {
        case SIGABRT: return "SIGABRT(\(sig))  —— 通常是被系统或断言终止（含 Swift 数组越界 / force unwrap nil）"
        case SIGSEGV: return "SIGSEGV(\(sig))  —— 访问了非法内存"
        case SIGBUS: return "SIGBUS(\(sig))  —— 内存对齐 / 映射错误"
        case SIGILL: return "SIGILL(\(sig))  —— 非法指令"
        case SIGFPE: return "SIGFPE(\(sig))  —— 算术异常"
        case SIGTRAP: return "SIGTRAP(\(sig))  —— 断点 / Swift 运行时 trap"
        default: return "SIG\(sig)"
        }
    }
}
