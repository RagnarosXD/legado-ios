//
//  CrashReporter.swift
//  Legado-iOS
//
//  崩溃捕获：
//  - ObjC 异常（NSException）：记录 name / reason / callStackSymbols
//  - 信号（SIGABRT / SIGSEGV / SIGBUS / SIGILL / SIGFPE）：只写内存里的最近日志，避免在信号上下文里做危险操作
//  崩溃文件写到 Documents/Logs/crash-*.log，下次启动会单独记一条「上次异常退出」
//

import Foundation
import Darwin
import UIKit

enum CrashReporter {

    private static var installed = false
    private static let launchFlagKey = "legado.lastLaunchFinished"

    // MARK: - 安装

    static func install() {
        guard !installed else { return }
        installed = true

        let previousLaunchFinished = UserDefaults.standard.bool(forKey: launchFlagKey)
        if previousLaunchFinished == false {
            AppLogger.warn("Crash", "检测到上次未正常退出，日志目录：\(AppLogger.directory.lastPathComponent)")
        }
        UserDefaults.standard.set(false, forKey: launchFlagKey)

        // 不依赖「是否正常退出」判断：只要磁盘上有还没导入过的崩溃报告就合并进主日志
        importPendingCrashReports()

        // ObjC 异常
        NSSetUncaughtExceptionHandler { exception in
            let callStack = exception.callStackSymbols
            CrashReporter.writeReport(
                kind: "NSException",
                detail: "name=\(exception.name.rawValue) reason=\(exception.reason ?? "-")",
                callStack: callStack
            )
        }

        // 崩溃文件预先打开：信号上下文里不能再做 FileManager / DateFormatter 之类的操作
        crashFileDescriptor = prepareCrashFile()

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

    // MARK: - 信号快照（async-signal-safe）

    private static var crashFileDescriptor: Int32 = -1

    private static func prepareCrashFile() -> Int32 {
        let directory = AppLogger.directory
        directory.path.withCString { _ = mkdir($0, 0o755) }

        let stamp = Int(Date().timeIntervalSince1970)
        let path = directory.appendingPathComponent("crash-\(stamp).log").path
        return path.withCString { open($0, O_WRONLY | O_CREAT | O_TRUNC, 0o644) }
    }

    private static func writeSignalSnapshot(_ sig: Int32) {
        let fd = crashFileDescriptor
        guard fd >= 0 else { return }

        writeCString("=== Legado CRASH (signal) ===\n", to: fd)
        writeCString(signalName(sig), to: fd)
        writeCString("\n--- backtrace ---\n", to: fd)

        // backtrace + backtrace_symbols_fd 是 async-signal-safe 的，不依赖 Swift/Foundation
        var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 96)
        let count = backtrace(&frames, 96)
        if count > 0 {
            backtrace_symbols_fd(&frames, count, fd)
        }

        writeCString("--- end ---\n", to: fd)
        fsync(fd)
    }

    private static func writeCString(_ text: String, to fd: Int32) {
        text.withCString { pointer in
            _ = write(fd, pointer, strlen(pointer))
        }
    }

    /// App 正常进入前台后标记一次，用来判断下次启动是否为异常退出
    static func markLaunchFinished() {
        UserDefaults.standard.set(true, forKey: launchFlagKey)
    }

    // MARK: - 把崩溃报告写进主日志

    private static let lastImportedCrashKey = "legado.lastImportedCrash"

    /// 之前的实现只在「上次启动未满 3 秒就退出」时才合并崩溃报告，
    /// 而崩溃通常发生在启动几秒之后，导致崩了也永远看不到调用栈。改为按文件去重。
    private static func importPendingCrashReports() {
        let directory = AppLogger.directory
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []

        let crashFiles = files
            .filter { $0.lastPathComponent.hasPrefix("crash-") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }

        guard let latest = crashFiles.first else {
            AppLogger.warn("Crash", "没有崩溃报告文件（可能是 watchdog / OOM 直接杀进程，未触发信号）")
            return
        }

        let lastImported = UserDefaults.standard.string(forKey: lastImportedCrashKey)
        guard latest.lastPathComponent != lastImported else { return }
        UserDefaults.standard.set(latest.lastPathComponent, forKey: lastImportedCrashKey)

        guard let text = try? String(contentsOf: latest, encoding: .utf8) else {
            AppLogger.warn("Crash", "崩溃报告读取失败：\(latest.lastPathComponent)")
            return
        }

        AppLogger.error("Crash", "===== 崩溃报告 \(latest.lastPathComponent) =====")
        for line in text.components(separatedBy: "\n").prefix(120) where !line.isEmpty {
            AppLogger.error("Crash", line)
        }
        AppLogger.error("Crash", "===== 崩溃报告结束 =====")
    }

    // MARK: - 落盘

    static func writeReport(kind: String, detail: String, callStack: [String]) {
        let directory = AppLogger.directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let stamp = timestamp()
        let url = directory.appendingPathComponent("crash-\(stamp).log")

        var lines: [String] = []
        lines.append("=== Legado 崩溃报告 ===")
        lines.append("kind: \(kind)")
        lines.append("detail: \(detail)")
        lines.append("version: \(AppLogger.appVersion)")
        lines.append("system: \(UIDevice.current.systemName) \(UIDevice.current.systemVersion) / \(UIDevice.current.model)")
        lines.append("time: \(Date())")
        if !callStack.isEmpty {
            lines.append("")
            lines.append("--- call stack ---")
            lines.append(contentsOf: callStack)
        }
        lines.append("")
        lines.append("--- recent logs ---")
        lines.append(contentsOf: AppLogger.shared.recentLinesSnapshot())

        let text = lines.joined(separator: "\n") + "\n"
        guard let data = text.data(using: .utf8) else { return }

        // 用低层 write，避免在崩溃上下文里依赖 FileHandle / Foundation 的锁
        url.path.withCString { path in
            let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
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
            close(fd)
        }
    }

    // MARK: - 工具

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    private static func signalName(_ sig: Int32) -> String {
        switch sig {
        case SIGABRT: return "SIGABRT(\(sig))"
        case SIGSEGV: return "SIGSEGV(\(sig))"
        case SIGBUS: return "SIGBUS(\(sig))"
        case SIGILL: return "SIGILL(\(sig))"
        case SIGFPE: return "SIGFPE(\(sig))"
        default: return "SIG\(sig)"
        }
    }
}
