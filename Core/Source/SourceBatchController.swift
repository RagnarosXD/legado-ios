//
//  SourceBatchController.swift
//  Legado-iOS
//
//  书源批量操作：批量校验（并发 + 进度）、按校验结果停用失败源
//

import Foundation
import SwiftUI

@MainActor
final class SourceBatchController: ObservableObject {

    @Published var isChecking = false
    @Published var checkedCount = 0
    @Published var totalCount = 0
    @Published var outcomes: [SourceCheckOutcome] = []

    var progress: Double {
        guard totalCount > 0 else { return 0 }
        return Double(checkedCount) / Double(totalCount)
    }

    var successCount: Int { outcomes.filter { $0.success }.count }
    var failureCount: Int { outcomes.filter { !$0.success }.count }

    /// 并发校验；并发度由用户设置（与搜索共用 searchConcurrency）
    func validate(_ sources: [BookSource], concurrency: Int) async {
        guard !sources.isEmpty, !isChecking else { return }

        isChecking = true
        outcomes = []
        checkedCount = 0
        totalCount = sources.count

        let limit = max(1, min(concurrency, 8))
        var pending = sources

        await withTaskGroup(of: SourceCheckOutcome.self) { group in
            var running = 0

            while !pending.isEmpty || running > 0 {
                while running < limit, !pending.isEmpty {
                    let source = pending.removeFirst()
                    group.addTask { await SourceValidator.check(source: source) }
                    running += 1
                }

                guard let outcome = await group.next() else { break }
                running -= 1
                outcomes.append(outcome)
                checkedCount += 1
            }
        }

        outcomes.sort { lhs, rhs in
            if lhs.success != rhs.success { return lhs.success && !rhs.success }
            return lhs.cost < rhs.cost
        }

        try? CoreDataStack.shared.save()
        isChecking = false

        AppLogger.info("Validate", "批量校验完成：\(successCount) 可用 / \(failureCount) 失败")
    }

    /// 把校验失败的源停用
    func disableFailed(in sources: [BookSource]) {
        let failedIds = Set(outcomes.filter { !$0.success }.map { $0.sourceId })
        guard !failedIds.isEmpty else { return }

        var changed = 0
        for source in sources where failedIds.contains(source.sourceId) && source.enabled {
            source.enabled = false
            changed += 1
        }
        try? CoreDataStack.shared.save()
        AppLogger.info("Validate", "已停用 \(changed) 个校验失败的书源")
    }
}
