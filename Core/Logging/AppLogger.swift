//
//  AppLogger.swift
//  Legado-iOS
//
//  运行日志：单一文件 Documents/Logs/legado.log（追加写入，不再每次启动新建）
//  - 启动时写一条分隔行（版本 + 时间），多次启动的记录都在同一个文件里
//  - 单文件超过 5MB 轮转为 legado.1.log（只保留 1 个历史，够回溯即可）
//  - 用 O_APPEND 的 fd 写入：崩溃时 CrashReporter 也能安全追加到同一个 fd
//  - 内存保留最近 400 条，供崩溃时兜底
//

import Foundation

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

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

    /// 统一的主日志文件名（崩溃报告也写这里）
    static let activeFileName = "legado.log"
    /// 轮转后的历史文件名
    static let archiveFileName = "legado.1.log"
    /// 超过该大小就轮转
    static let maxFileSize: Int = 5 * 1024 * 1024

    private let queue = DispatchQueue(label: "com.legado.applogger", qos: .utility)
    private let memoryLock = NSLock()
    private var memoryLines: [String] = []
    private let maxMemoryLines = 400

    /// O_APPEND 的 fd：与 CrashReporter 共享同一文件，两边都追加写
    private var fileDescriptor: Int32 = -1
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

    /// 当前日志文件（导出用）
    var currentLogFile: URL {
        if let url = currentURL {
            return url
        }
        let url = Self.directory.appendingPathComponent(Self.activeFileName)
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        return url
    }

    /// 所有日志文件（主日志 + 轮转历史 + 旧版遗留），按名称排序
    func allLogFiles() -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: Self.directory,
            includingPropertiesForKeys: nil
        )) ?? []
        return contents
            .filter { $0.pathExtension == "log" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// 供 CrashReporter 在信号上下文里复用：预先打开追加模式的 fd
    /// （信号处理里不能再做 FileManager / open 之类的操作）
    static func openAppendDescriptor() -> Int32 {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent(activeFileName).path
        return path.withCString { open($0, O_WRONLY | O_CREAT | O_APPEND, 0o644) }
    }

    /// 跨平台追加写（Darwin / Glibc 的 write 符号不同，且不能与本类的 write(level:) 混淆）
    private static func rawWrite(_ fd: Int32, _ buffer: UnsafeRawBufferPointer) {
        guard fd >= 0, let base = buffer.baseAddress else { return }
        #if canImport(Darwin)
        _ = Darwin.write(fd, base, buffer.count)
        #else
        _ = Glibc.write(fd, base, buffer.count)
        #endif
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

        // 直接 write 到内核（O_APPEND 原子追加，约 10 微秒），不做 fsync。
        // 原因：
        // 1) write 进内核页缓存后，即使进程被 SIGKILL，数据也会由系统刷盘 —— 不会丢
        // 2) 之前的 fsync（每条 1~5ms）会把主线程拖到 watchdog 杀进程
        // 3) 之前的 queue.async 版本，进程被强杀时队列里的日志会丢失
        // fd 是 Int32，读取是原子的；只在 deleteAllLogs 里重建
        let fd = fileDescriptor
        guard fd >= 0 else { return }
        data.withUnsafeBytes { buffer in
            Self.rawWrite(fd, buffer)
        }
    }

    /// 实际写入（只在 queue 上调用）
    private func writeData(_ data: Data) {
        guard fileDescriptor >= 0 else { return }
        data.withUnsafeBytes { buffer in
            Self.rawWrite(fileDescriptor, buffer)
        }
    }

    /// 刷盘（只在 queue 上调用）
    private func flushFile() {
        guard fileDescriptor >= 0 else { return }
        fsync(fileDescriptor)
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

    /// 打开（或创建）主日志文件：追加写入，不新建文件；
    /// 超过上限时先把旧文件轮转为 legado.1.log，再以空的 legado.log 继续
    private func openLogFile() {
        queue.sync {
            let directory = Self.directory
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            let url = directory.appendingPathComponent(Self.activeFileName)

            // 超过上限先轮转
            if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
               let size = attributes[.size] as? Int,
               size > Self.maxFileSize {
                Self.rotate(in: directory)
            }

            fileDescriptor = url.path.withCString { open($0, O_WRONLY | O_CREAT | O_APPEND, 0o644) }
            currentURL = url

            // 启动分隔：多次启动的记录都在同一个文件里，靠这行区分会话
            writeSessionSeparator()
        }
    }

    private static func rotate(in directory: URL) {
        let active = directory.appendingPathComponent(activeFileName)
        let archive = directory.appendingPathComponent(archiveFileName)
        try? FileManager.default.removeItem(at: archive)
        try? FileManager.default.moveItem(at: active, to: archive)
    }

    private func writeSessionSeparator() {
        guard fileDescriptor >= 0 else { return }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let line = "\n========== 启动 v\(Self.appVersion) \(formatter.string(from: Date())) ==========\n"

        guard let data = line.data(using: .utf8) else { return }
        data.withUnsafeBytes { buffer in
            Self.rawWrite(fileDescriptor, buffer)
        }
        fsync(fileDescriptor)
    }

    /// 删除全部日志文件，并继续写主日志
    func deleteAllLogs() {
        queue.sync {
            if fileDescriptor >= 0 {
                close(fileDescriptor)
                fileDescriptor = -1
            }

            for url in allLogFiles() {
                try? FileManager.default.removeItem(at: url)
            }

            // 旧版按次生成的 app-*.log / crash-*.log 也一并清掉
            let legacy = (try? FileManager.default.contentsOfDirectory(
                at: Self.directory,
                includingPropertiesForKeys: nil
            )) ?? []
            for url in legacy where url.lastPathComponent.hasPrefix("app-") || url.lastPathComponent.hasPrefix("crash-") {
                try? FileManager.default.removeItem(at: url)
            }

            let url = Self.directory.appendingPathComponent(Self.activeFileName)
            fileDescriptor = url.path.withCString { open($0, O_WRONLY | O_CREAT | O_APPEND, 0o644) }
            currentURL = url
        }

        Self.warn("Log", "日志已清除")
    }

    /// 把散落的崩溃报告（旧版 crash-*.log）合并进主日志，合并后删除源文件
    func mergeLegacyCrashReports() {
        let directory = Self.directory
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []

        let crashFiles = files
            .filter { $0.lastPathComponent.hasPrefix("crash-") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        guard !crashFiles.isEmpty else { return }

        for file in crashFiles {
            let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

            if trimmed.isEmpty {
                // 空报告（旧版每次启动预创建的那种）直接删除，不当作崩溃
                try? FileManager.default.removeItem(at: file)
                continue
            }

            Self.error("Crash", "===== 合并崩溃报告 \(file.lastPathComponent) =====")
            for line in trimmed.components(separatedBy: "\n").prefix(200) where !line.isEmpty {
                Self.error("Crash", line)
            }
            Self.error("Crash", "===== 崩溃报告结束 \(file.lastPathComponent) =====")

            try? FileManager.default.removeItem(at: file)
        }
    }
}

// MARK: - 当前处理进度（崩溃后下次启动能直接看到最后在干什么）

/// 每次覆盖写一个极小文件：`Documents/Logs/state.txt`
/// 用途：进程被 SIGKILL（watchdog / OOM / 手动划掉）时，信号处理不会执行，
/// 但这个小文件始终反映「最后一步在做什么」，下次启动会把它打到日志开头。
enum ProgressRecorder {

    private static var fileURL: URL {
        AppLogger.directory.appendingPathComponent("state.txt")
    }

    @inline(__always)
    static func record(_ text: String) {
        try? FileManager.default.createDirectory(at: AppLogger.directory, withIntermediateDirectories: true)
        // 小文件覆盖写（临时文件 + rename），比日志写入更可靠地反映最新状态
        try? text.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    static func lastState() -> String? {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}

// MARK: - 主线程卡顿检测（避免新增文件需改 pbxproj）
final class MainThreadWatchdog {

    static let shared = MainThreadWatchdog()

    private let lock = NSLock()
    private var lastBeat = Date()
    private var stage = "启动"
    private var reported = false
    private var timer: DispatchSourceTimer?

    private init() {}

    func start() {
        guard timer == nil else { return }

        // 主线程心跳：主线程被占用时不会触发，正是检测依据
        let heartbeat = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.beat("空闲")
        }
        RunLoop.main.add(heartbeat, forMode: .common)

        let source = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "legado.watchdog", qos: .utility))
        source.schedule(deadline: .now() + 2, repeating: 1)
        source.setEventHandler { [weak self] in
            self?.check()
        }
        source.resume()
        timer = source

        beat("启动完成")
    }

    /// 主线程标记当前阶段（长任务开始前调用，卡住时日志里能看到是哪一个）
    func beat(_ newStage: String) {
        lock.lock()
        lastBeat = Date()
        stage = newStage
        reported = false
        lock.unlock()
    }

    private func check() {
        lock.lock()
        let elapsed = Date().timeIntervalSince(lastBeat)
        let current = stage
        let alreadyReported = reported
        if elapsed > 5 {
            reported = true
        }
        lock.unlock()

        guard elapsed > 5, !alreadyReported else { return }

        AppLogger.error("Watchdog", "主线程已卡住 \(Int(elapsed)) 秒，最后阶段：\(current)")
    }
}
