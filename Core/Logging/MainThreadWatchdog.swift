//
//  MainThreadWatchdog.swift
//  Legado-iOS
//
//  主线程卡顿检测：
//  - 主线程每秒打一次心跳（Timer），卡住时 Timer 不会触发
//  - 后台队列每秒检查心跳间隔，超过 8 秒就写一条 ERROR
//  - 用途：区分「崩溃」与「主线程卡死被 watchdog 杀掉」（后者无法拿到 backtrace）
//
//  关键：日志走 AppLogger，而 INFO/DEBUG 是异步写、不阻塞主线程，
//  所以主线程卡住期间后台仍能写入这条记录。
//

import Foundation

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
        if elapsed > 8 {
            reported = true
        }
        lock.unlock()

        guard elapsed > 8, !alreadyReported else { return }

        AppLogger.error("Watchdog", "主线程已卡住 \(Int(elapsed)) 秒，最后阶段：\(current)")
    }
}
