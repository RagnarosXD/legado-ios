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

        // ObjC 异常
        NSSetUncaughtExceptionHandler { exception in
            let callStack = exception.callStackSymbols
            CrashReporter.writeReport(
                kind: "NSException",
                detail: "name=\(exception.name.rawValue) reason=\(exception.reason ?? "-")",
                callStack: callStack
            )
        }

        // 信号
        let signals: [Int32] = [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE]
        for sig in signals {
            signal(sig) { received in
                CrashReporter.writeReport(
                    kind: "Signal",
                    detail: "signal=\(CrashReporter.signalName(received))",
                    callStack: []
                )
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
