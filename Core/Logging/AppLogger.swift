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

    enum Level: String {
        case debug = "D"
        case info = "I"
        case warn = "W"
        case error = "E"
        case crash = "C"
    }

    // MARK: - 配置

    private let queue = DispatchQueue(label: "com.legado.applogger", qos: .utility)
    private let memoryLock = NSLock()
    private var memoryLines: [String] = []
    private let maxMemoryLines = 400

    private let maxFileSize: UInt64 = 2 * 1024 * 1024
    private let maxFileCount = 3

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
        let url = Self.directory.appendingPathComponent("app.log")
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
        let time = Self.makeFormatter().string(from: Date())
        let shortFile = (file as NSString).lastPathComponent
        let text = "\(time) [\(level.rawValue)] \(tag) \(shortFile):\(line) \(message)"

        appendMemory(text)

        queue.async { [weak self] in
            guard let self else { return }
            guard let data = (text + "\n").data(using: .utf8) else { return }
            self.handle?.write(data)
            try? self.handle?.synchronize()
            self.rotateIfNeeded()
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

    private func openLogFile() {
        queue.async { [weak self] in
            guard let self else { return }
            let directory = Self.directory
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            let url = directory.appendingPathComponent("app.log")
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            self.handle = try? FileHandle(forWritingTo: url)
            self.handle?.seekToEndOfFile()
            self.currentURL = url
        }
    }

    private func rotateIfNeeded() {
        guard let currentHandle = handle,
              let size = try? currentHandle.seekToEnd(),
              size > maxFileSize else { return }

        currentHandle.closeFile()
        handle = nil

        let directory = Self.directory
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        let archive = directory.appendingPathComponent("app-\(stamp).log")
        try? FileManager.default.moveItem(at: directory.appendingPathComponent("app.log"), to: archive)

        trimArchives()

        let url = directory.appendingPathComponent("app.log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
        currentURL = url
    }

    private func trimArchives() {
        let archives = allLogFiles().filter { $0.lastPathComponent != "app.log" }
        guard archives.count > maxFileCount else { return }
        for url in archives.dropFirst(maxFileCount) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
