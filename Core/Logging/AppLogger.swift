//
//  AppLogger.swift
//  Legado-iOS
//
//  运行日志：落盘到 Documents/Logs/app-*.log
//  - 固定大小滚动（单文件 2MB，保留 3 个）
//  - 内存保留最近 400 条，崩溃时由 CrashReporter 落盘
//  - 设置页可导出，便于用户在无 Mac 的环境反馈闪退原因
//

import Foundation

final class AppLogger {

    static let shared = AppLogger()

    enum Level: String, CaseIterable {
        case debug = "D"
        case info = "I"
        case warn = "W"
        case error = "E"
        case crash = "C"

        var rank: Int {
            switch self {
            case .debug: return 0
            case .info: return 1
            case .warn: return 2
            case .error: return 3
            case .crash: return 4
            }
        }

        var title: String {
            switch self {
            case .debug: return "调试"
            case .info: return "信息"
            case .warn: return "警告"
            case .error: return "错误"
            case .crash: return "崩溃"
            }
        }
    }

    /// 低于该级别的日志不写盘（崩溃始终记录）
    static var minimumLevel: Level {
        get {
            guard let raw = UserDefaults.standard.string(forKey: "logLevel"),
                  let level = Level.allCases.first(where: { $0.title == raw || $0.rawValue == raw }) else {
                return .debug
            }
            return level
        }
        set {
            UserDefaults.standard.set(newValue.title, forKey: "logLevel")
        }
    }

    // MARK: - 配置

    private let queue = DispatchQueue(label: "com.legado.applogger", qos: .utility)
    private let memoryLock = NSLock()
    private var memoryLines: [String] = []
    private let maxMemoryLines = 400

    /// 最多保留的日志文件数（每次启动一个文件）
    private let maxFileCount = 12

    private var handle: FileHandle?
    private var currentURL: URL?

    /// DateFormatter 不是线程安全的，日志可能从任意线程写入，这里每次新建（开销可忽略）
    private static func makeFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss.SSS"
        return formatter
    }

    private init() {
        openLogFile()
    }

    // MARK: - 路径

    static var directory: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("Logs", isDirectory: true)
    }

    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short)(\(build))"
    }

    /// 当前日志文件（导出用），始终返回一个可分享的 URL
    var currentLogFile: URL {
        if let url = currentURL {
            return url
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        let url = Self.directory.appendingPathComponent("app-\(stamp).log")
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        return url
    }

    func allLogFiles() -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: Self.directory,
            includingPropertiesForKeys: nil
        )) ?? []
        return contents
            .filter { $0.pathExtension == "log" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    // MARK: - 记录

    static func debug(_ tag: String, _ message: @autoclosure () -> String, file: String = #fileID, line: Int = #line) {
        shared.write(.debug, tag, message(), file: file, line: line)
    }

    static func info(_ tag: String, _ message: @autoclosure () -> String, file: String = #fileID, line: Int = #line) {
        shared.write(.info, tag, message(), file: file, line: line)
    }

    static func warn(_ tag: String, _ message: @autoclosure () -> String, file: String = #fileID, line: Int = #line) {
        shared.write(.warn, tag, message(), file: file, line: line)
    }

    static func error(_ tag: String, _ message: @autoclosure () -> String, file: String = #fileID, line: Int = #line) {
        shared.write(.error, tag, message(), file: file, line: line)
    }

    private func write(_ level: Level, _ tag: String, _ message: String, file: String, line: Int) {
        guard level.rank >= Self.minimumLevel.rank else { return }

        let time = Self.makeFormatter().string(from: Date())
        let shortFile = (file as NSString).lastPathComponent
        let text = "\(time) [\(level.rawValue)] \(tag) \(shortFile):\(line) \(message)"

        appendMemory(text)

        guard let data = (text + "\n").data(using: .utf8) else { return }

        // 同步写 + 立即 flush：之前用 queue.async，进程被系统杀掉（watchdog / OOM）时
        // 队列里最后几秒的日志全丢了，看起来「日志太少」。日志量本身很小，同步成本可接受。
        queue.sync {
            handle?.write(data)
            try? handle?.synchronize()
        }
    }

    private func appendMemory(_ line: String) {
        memoryLock.lock()
        memoryLines.append(line)
        if memoryLines.count > maxMemoryLines {
            memoryLines.removeFirst(memoryLines.count - maxMemoryLines)
        }
        memoryLock.unlock()
    }

    /// 崩溃时读取（signal 上下文调用，用 try-lock 避免死锁）
    func recentLinesSnapshot(limit: Int = 200) -> [String] {
        guard memoryLock.try() else { return ["<日志被占用，跳过>"] }
        defer { memoryLock.unlock() }
        return Array(memoryLines.suffix(limit))
    }

    // MARK: - 文件管理

    /// 每次启动新建一个 app-yyyyMMdd-HHmmss.log，文件名即启动时间（精确到秒），不需要手动改名
    private func openLogFile() {
        queue.async { [weak self] in
            guard let self else { return }
            let directory = Self.directory
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let stamp = formatter.string(from: Date())

            var url = directory.appendingPathComponent("app-\(stamp).log")
            var suffix = 2
            while FileManager.default.fileExists(atPath: url.path) {
                url = directory.appendingPathComponent("app-\(stamp)-\(suffix).log")
                suffix += 1
            }

            FileManager.default.createFile(atPath: url.path, contents: nil)
            self.handle = try? FileHandle(forWritingTo: url)
            self.currentURL = url

            self.trimArchives(keeping: self.maxFileCount)
        }
    }

    /// 删除全部日志文件，并新建一个空文件继续记录
    func deleteAllLogs() {
        queue.sync {
            handle?.closeFile()
            handle = nil

            for url in allLogFiles() {
                try? FileManager.default.removeItem(at: url)
            }

            let url = Self.directory.appendingPathComponent(Self.makeLogFileName())
            FileManager.default.createFile(atPath: url.path, contents: nil)
            handle = try? FileHandle(forWritingTo: url)
            currentURL = url
        }

        Self.warn("Log", "日志已清除")
    }

    private static func makeLogFileName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "app-\(formatter.string(from: Date())).log"
    }

    /// 只保留最近 N 个日志文件
    private func trimArchives(keeping count: Int) {
        let logs = allLogFiles()   // 已按文件名（即时间）降序
        guard logs.count > count else { return }
        for url in logs.dropFirst(count) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
