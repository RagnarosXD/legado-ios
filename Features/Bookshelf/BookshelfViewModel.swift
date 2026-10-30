//
//  BookshelfViewModel.swift
//  Legado-iOS
//
//  书架 ViewModel
//

import Foundation
import CoreData
import Combine

@MainActor
final class BookshelfViewModel: ObservableObject {
    @Published var books: [Book] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var hasMore = true
    
    @Published var viewMode: ViewMode = .grid
    @Published var groupFilter: Int32 = 0
    @Published var sortBy: SortBy = .lastRead
    
    private let pageSize = 50
    private var currentPage = 0
    
    enum ViewMode: Int, CaseIterable {
        case grid = 0
        case list = 1
    }
    
    enum SortBy: Int, CaseIterable {
        case lastRead = 0
        case name = 1
        case author = 2
        case update = 3
    }
    
    private var loadTask: Task<Void, Never>?
    
    deinit {
        loadTask?.cancel()
    }
    
    func loadBooks() async {
        guard !isLoading else { return }

        isLoading = true
        currentPage = 0

        do {
            let firstPage = try await fetchBooks(page: 0, size: pageSize)
            print("📚 loadBooks: 获取到 \(firstPage.count) 本书")
            for book in firstPage.prefix(3) {
                print("  - \(book.name) (origin: \(book.origin))")
            }
            books = firstPage
            hasMore = firstPage.count == pageSize
            normalizeCoverURLs()
        } catch {
            errorMessage = "加载失败：\(error.localizedDescription)"
            print("❌ loadBooks 失败: \(error)")
        }

        isLoading = false
    }
    
    func forceReload() async {
        print("🔄 forceReload: 强制刷新书架")
        isLoading = false
        await loadBooks()
    }
    
    func loadMoreBooks() async {
        guard !isLoading && hasMore else { return }

        isLoading = true

        do {
            currentPage += 1
            let nextPage = try await fetchBooks(page: currentPage, size: pageSize)
            books.append(contentsOf: nextPage)
            hasMore = nextPage.count == pageSize
        } catch {
            errorMessage = "加载更多失败：\(error.localizedDescription)"
        }

        isLoading = false
    }
    
    /// 旧数据里的封面可能是相对路径（`/img/1.jpg`），书名页因此显示占位图。
    /// 这里按书源地址补全成绝对地址并保存一次。
    private func normalizeCoverURLs() {
        let context = CoreDataStack.shared.viewContext
        var changed = 0

        for book in books {
            guard let rawCover = book.coverUrl else { continue }
            let cover = rawCover.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cover.isEmpty,
                  !cover.hasPrefix("http"),
                  !cover.hasPrefix("data:") else { continue }

            guard let source = BookSourceResolver.resolve(for: book, in: context),
                  let base = URL(string: source.bookSourceUrl),
                  let absolute = URL(string: cover, relativeTo: base)?.absoluteString else { continue }

            book.coverUrl = absolute
            changed += 1
        }

        if changed > 0 {
            try? context.save()
            AppLogger.info("Bookshelf", "补全 \(changed) 本书的封面地址")
        }
    }

    private func fetchBooks(page: Int, size: Int) async throws -> [Book] {
        let context = CoreDataStack.shared.viewContext

        let request: NSFetchRequest<Book> = Book.fetchRequest()
        request.fetchLimit = size
        request.fetchOffset = page * size

        if groupFilter != 0 {
            request.predicate = NSPredicate(format: "group == %d", groupFilter)
        }

        switch sortBy {
        case .lastRead:
            request.sortDescriptors = [NSSortDescriptor(key: "durChapterTime", ascending: false)]
        case .name:
            request.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        case .author:
            request.sortDescriptors = [NSSortDescriptor(key: "author", ascending: true)]
        case .update:
            request.sortDescriptors = [NSSortDescriptor(key: "lastCheckTime", ascending: false)]
        }

        return try context.fetch(request)
    }
    
    func refreshBooks() async {
        await loadBooks()
    }
    
    func removeBook(_ book: Book) {
        let id = book.bookId
        CoreDataStack.shared.viewContext.delete(book)
        // 同步摘掉，避免 SwiftUI 下一帧为已失效对象求 id / 渲染
        books.removeAll { $0.bookId == id }
        try? CoreDataStack.shared.save()
    }
    
    func updateGroup(for book: Book, group: Int32) {
        book.group = Int64(group)
        try? CoreDataStack.shared.save()
    }
}