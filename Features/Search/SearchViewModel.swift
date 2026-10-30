//
//  SearchViewModel.swift
//  Legado-iOS
//
//  搜索 ViewModel
//

import Foundation
import CoreData

@MainActor
class SearchViewModel: ObservableObject {
    @Published var searchText: String = ""
    @Published var searchResults: [SearchResult] = []
    @Published var isSearching = false
    @Published var errorMessage: String?
    @Published var selectedSources: [BookSource] = []
    
    private var ruleEngine: RuleEngine = RuleEngine()

    init() {
        loadDefaultSources()
    }

    private func loadDefaultSources() {
        do {
            let sources = try CoreDataStack.shared.viewContext.fetch(BookSource.fetchRequest())
            selectedSources = sources.filter { $0.enabled && $0.searchUrl != nil }
        } catch {
            selectedSources = []
        }
    }
    
    // MARK: - 搜索结果
    struct SearchResult: Identifiable {
        let id = UUID()
        let name: String
        let author: String
        let coverUrl: String?
        let intro: String?
        let sourceName: String
        let sourceId: UUID
        let bookUrl: String
        
        var displayName: String {
            name.trimmingCharacters(in: .whitespaces)
        }
        
        var displayAuthor: String {
            author.trimmingCharacters(in: .whitespaces)
        }
    }
    
    // MARK: - 执行搜索
    func search(keyword: String, sources: [BookSource]) async {
        guard !keyword.isEmpty else {
            searchResults = []
            isSearching = false
            return
        }
        
        isSearching = true
        searchResults.removeAll()
        errorMessage = nil

        let enabledSources = sources.filter { $0.enabled && $0.searchUrl != nil }
        var merged: [SearchResult] = []
        var failures: [String] = []

        AppLogger.info("Search", "开始搜索 keyword=\(keyword) 书源数=\(enabledSources.count)")

        // 串行搜索：书源是 Core Data 对象、规则解析会创建 JavaScriptCore 上下文，
        // 两者都不允许被多个任务并发触碰。之前用 withTaskGroup 并发多源，
        // 订阅一批带 JS 规则的书源后，首次并发创建 JS VM 会直接闪退。
        // 用户可能导入几百个源，串行搜索必须有总时长上限，否则一直转圈
        let deadline = Date().addingTimeInterval(90)

        for source in enabledSources {
            if Task.isCancelled {
                AppLogger.warn("Search", "搜索被取消")
                break
            }
            if Date() > deadline {
                AppLogger.warn("Search", "已达搜索时间上限（90s），剩余 \(enabledSources.count - merged.count) 个源未搜索")
                break
            }

            let startedAt = Date()
            AppLogger.info("Search", "书源开始 \(source.displayName) type=\(source.bookSourceType) url=\(source.bookSourceUrl)")

            do {
                let partial = try await searchInSource(keyword: keyword, source: source)
                let cost = Int(Date().timeIntervalSince(startedAt) * 1000)
                AppLogger.info("Search", "书源完成 \(source.displayName) 结果=\(partial.count) 耗时=\(cost)ms")

                if !partial.isEmpty {
                    merged.append(contentsOf: partial)
                    // 边搜边出结果，避免长等待
                    searchResults = merged
                }
            } catch {
                let cost = Int(Date().timeIntervalSince(startedAt) * 1000)
                // 单个源失败不再中断整体搜索，但把原因带出来，便于判断是书源问题还是 App 问题
                AppLogger.error("Search", "书源失败 \(source.displayName) 耗时=\(cost)ms 错误=\(error)")
                failures.append("\(source.displayName)：\(error.localizedDescription)")
                continue
            }
        }

        AppLogger.info("Search", "搜索结束 结果=\(merged.count) 失败源=\(failures.count)")

        if merged.isEmpty, !failures.isEmpty {
            let preview = failures.prefix(3).joined(separator: "\n")
            errorMessage = "没有搜索到结果，失败原因：\n\(preview)"
        }

        isSearching = false
    }
    
    // MARK: - 在单个书源中搜索
    private func searchInSource(keyword: String, source: BookSource) async throws -> [SearchResult] {
        // 使用 WebBook 进行搜索
        let results = try await WebBook.searchBook(source: source, key: keyword)
        
        return results.map { searchBook in
            SearchResult(
                name: searchBook.name,
                author: searchBook.author,
                coverUrl: searchBook.coverUrl,
                intro: searchBook.intro,
                sourceName: source.bookSourceName,
                sourceId: source.sourceId,
                bookUrl: searchBook.bookUrl
            )
        }
    }
    
    // MARK: - 添加到书架
    func addToBookshelf(result: SearchResult) async throws -> Book {
        let context = CoreDataStack.shared.viewContext

        if let existing = findBook(bookUrl: result.bookUrl, origin: result.sourceId.uuidString, in: context) {
            existing.name = result.name
            existing.author = result.author
            existing.coverUrl = result.coverUrl
            existing.intro = result.intro
            existing.originName = result.sourceName
            existing.updatedAt = Date()
            try CoreDataStack.shared.save()
            return existing
        }

        let book = Book.create(in: context)
        book.name = result.name
        book.author = result.author
        book.coverUrl = result.coverUrl
        book.intro = result.intro
        book.bookUrl = result.bookUrl
        book.tocUrl = ""
        book.origin = result.sourceId.uuidString
        book.originName = result.sourceName

        let sourceRequest: NSFetchRequest<BookSource> = BookSource.fetchRequest()
        sourceRequest.fetchLimit = 1
        sourceRequest.predicate = NSPredicate(format: "sourceId == %@", result.sourceId as CVarArg)
        if let source = try? context.fetch(sourceRequest).first {
            book.source = source
        }

        try CoreDataStack.shared.save()
        return book
    }

    private func findBook(bookUrl: String, origin: String, in context: NSManagedObjectContext) -> Book? {
        let request: NSFetchRequest<Book> = Book.fetchRequest()
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "bookUrl == %@ AND origin == %@", bookUrl, origin)
        return try? context.fetch(request).first
    }
}

// MARK: - 错误类型
enum SearchError: LocalizedError {
    case invalidSource
    case noSearchRule
    case networkFailure
    
    var errorDescription: String? {
        switch self {
        case .invalidSource: return "书源无效"
        case .noSearchRule: return "缺少搜索规则"
        case .networkFailure: return "网络请求失败"
        }
    }
}
