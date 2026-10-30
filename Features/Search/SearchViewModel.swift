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

    /// 聚合结果：书名 + 作者相同视为同一本书，可切换书源
    @Published var mergedResults: [MergedSearchResult] = []

    // MARK: - 搜索进度
    @Published var searchedSourceCount = 0
    @Published var totalSourceCount = 0

    var progress: Double {
        guard totalSourceCount > 0 else { return 0 }
        return min(1, Double(searchedSourceCount) / Double(totalSourceCount))
    }
    
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

    /// 聚合同一本书的多个书源结果
    struct MergedSearchResult: Identifiable {
        let key: String
        var entries: [SearchResult]

        var id: String { key }

        var name: String { entries.first?.displayName ?? "" }
        var author: String { entries.first?.displayAuthor ?? "" }
        var coverUrl: String? { entries.first?.coverUrl }
        var intro: String? { entries.first?.intro }
        var primary: SearchResult? { entries.first }

        var sourceNames: [String] {
            entries.map { $0.sourceName }
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
        mergedResults.removeAll()
        errorMessage = nil
        searchedSourceCount = 0

        let allEnabled = sources.filter { $0.enabled && $0.searchUrl != nil }
        // 本版本只有文本阅读器：有声/漫画/图片源的响应结构完全不同，混进文本解析会崩
        let enabledSources = allEnabled.filter { $0.supportsTextSearch }
        let skippedCount = allEnabled.count - enabledSources.count
        if skippedCount > 0 {
            AppLogger.warn("Search", "跳过 \(skippedCount) 个非文本书源（有声/漫画/图片），本版本仅支持电子书文本源")
        }

        totalSourceCount = enabledSources.count
        let limit = max(1, min(configuredConcurrency(), 8))

        var collected: [SearchResult] = []
        var failures: [String] = []

        AppLogger.info("Search", "开始搜索 keyword=\(keyword) 文本源=\(enabledSources.count) 跳过=\(skippedCount) 并发=\(limit)")

        // 并发搜索：任务里通过 await 回到 MainActor 执行 searchInSource，
        // 耗时主要在 await 网络（此时主线程已释放），解析仍在主线程串行，
        // 既不跨线程碰 Core Data，又能把网络等待叠起来
        let deadline = Date().addingTimeInterval(90)

        await withTaskGroup(of: (name: String, results: [SearchResult], failure: String?).self) { group in
            var pending = enabledSources
            var running = 0

            while !pending.isEmpty || running > 0 {
                let expired = Date() > deadline

                while running < limit, !pending.isEmpty, !expired {
                    let source = pending.removeFirst()
                    let name = source.displayName
                    group.addTask { [weak self] in
                        guard let self else { return (name, [], nil) }
                        do {
                            let results = try await self.searchInSource(keyword: keyword, source: source)
                            return (name, results, nil)
                        } catch {
                            return (name, [], "\(name)：\(error.localizedDescription)")
                        }
                    }
                    running += 1
                }

                guard let outcome = await group.next() else { break }
                running -= 1
                searchedSourceCount += 1

                if let failure = outcome.failure {
                    failures.append(failure)
                    AppLogger.error("Search", "书源失败 \(failure)")
                }
                if !outcome.results.isEmpty {
                    collected.append(contentsOf: outcome.results)
                    searchResults = collected
                    rebuildMergedResults()
                }
                AppLogger.info("Search", "书源完成 \(outcome.name) 结果=\(outcome.results.count) 进度=\(searchedSourceCount)/\(totalSourceCount)")
            }
        }

        searchResults = collected
        rebuildMergedResults()
        AppLogger.info("Search", "搜索结束 结果=\(collected.count) 聚合=\(mergedResults.count) 失败源=\(failures.count)")

        // 把「这本书在哪些源里命中过」存下来，换源时不必重新全量搜索
        persistSourceCache()

        if collected.isEmpty {
            if enabledSources.isEmpty, skippedCount > 0 {
                errorMessage = "启用的书源都是有声/漫画/图片类型（\(skippedCount) 个），当前版本只支持电子书文本源。"
            } else if !failures.isEmpty {
                let preview = failures.prefix(3).joined(separator: "\n")
                errorMessage = "没有搜索到结果，失败原因：\n\(preview)"
            }
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

    // MARK: - 聚合

    /// 把同书名 + 同作者的结果合成一条，保留全部来源
    private func rebuildMergedResults() {
        var buckets: [String: MergedSearchResult] = [:]
        var order: [String] = []

        for result in searchResults {
            let name = result.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let author = result.author.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = "\(name)|\(author)"

            if var existing = buckets[key] {
                if !existing.entries.contains(where: { $0.sourceId == result.sourceId }) {
                    existing.entries.append(result)
                }
                buckets[key] = existing
            } else {
                buckets[key] = MergedSearchResult(key: key, entries: [result])
                order.append(key)
            }
        }

        mergedResults = order.compactMap { buckets[$0] }
    }

    /// 命中结果写入换源缓存
    private func persistSourceCache() {
        guard !mergedResults.isEmpty else { return }

        var urlById: [UUID: String] = [:]
        for source in selectedSources {
            urlById[source.sourceId] = source.bookSourceUrl
        }

        for merged in mergedResults {
            let hits = merged.entries.compactMap { entry -> CachedSourceHit? in
                guard !entry.bookUrl.isEmpty else { return nil }
                return CachedSourceHit(
                    sourceId: entry.sourceId,
                    sourceName: entry.sourceName,
                    sourceUrl: urlById[entry.sourceId] ?? "",
                    bookUrl: entry.bookUrl,
                    coverUrl: entry.coverUrl,
                    intro: entry.intro,
                    cachedAt: Date()
                )
            }
            SearchSourceCache.shared.save(name: merged.name, author: merged.author, hits: hits)
        }
    }

    /// 用户设置的搜索并发数（设置页写入）
    private func configuredConcurrency() -> Int {
        let stored = UserDefaults.standard.integer(forKey: "searchConcurrency")
        return stored > 0 ? stored : 4
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
