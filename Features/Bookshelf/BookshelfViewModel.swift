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
    /// nil = 全部；否则按 Android 的位掩码语义 `(book.group & groupId) > 0` 过滤
    @Published var selectedGroupId: Int64? = nil
    @Published var groups: [BookGroup] = []
    @Published var sortBy: SortBy = .lastRead
    
    private let pageSize = 50
    private var currentPage = 0
    
    enum ViewMode: Int, CaseIterable {
        case grid = 0
        case list = 1
    }
    
    /// 排序枚举与 Android `bookshelfSort` 编号一致
    enum SortBy: Int, CaseIterable {
        case lastRead = 0     // 最后阅读时间（durChapterTime）降序
        case update = 1       // 更新时间（latestChapterTime）降序
        case name = 2         // 书名
        case manual = 3       // 手动排序（order 升序）
        case combined = 4     // max(更新时间, 阅读时间) 降序
        case author = 5       // 作者

        var title: String {
            switch self {
            case .lastRead: return "最近阅读"
            case .update: return "更新时间"
            case .name: return "书名"
            case .manual: return "手动排序"
            case .combined: return "综合排序"
            case .author: return "作者"
            }
        }

        var icon: String {
            switch self {
            case .lastRead: return "clock"
            case .update: return "arrow.triangle.2.circlepath"
            case .name: return "textformat"
            case .manual: return "hand.draw"
            case .combined: return "square.stack.3d.up"
            case .author: return "person"
            }
        }
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
            loadGroups()
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

        // Android 用位掩码标识分组（一本书可属于多个分组），Core Data 谓词不支持位运算，
        // 选中分组时取全量后内存过滤再切片
        if selectedGroupId == nil {
            request.fetchLimit = size
            request.fetchOffset = page * size
        }

        switch sortBy {
        case .lastRead:
            request.sortDescriptors = [NSSortDescriptor(key: "durChapterTime", ascending: false)]
        case .update:
            request.sortDescriptors = [NSSortDescriptor(key: "latestChapterTime", ascending: false)]
        case .name:
            request.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        case .manual:
            request.sortDescriptors = [NSSortDescriptor(key: "order", ascending: true)]
        case .combined:
            request.sortDescriptors = [
                NSSortDescriptor(key: "latestChapterTime", ascending: false),
                NSSortDescriptor(key: "durChapterTime", ascending: false)
            ]
        case .author:
            request.sortDescriptors = [NSSortDescriptor(key: "author", ascending: true)]
        }

        if selectedGroupId != nil {
            let all = try context.fetch(request)
            let filtered = applyGroupFilter(to: all)
            let start = page * size
            let end = min(start + size, filtered.count)
            guard start < end else { return [] }
            return Array(filtered[start..<end])
        }

        return try context.fetch(request)
    }

    /// 切换分组后重新加载
    func selectGroup(_ groupId: Int64?) {
        selectedGroupId = groupId
        Task { await loadBooks() }
    }
    
    /// 全部分组（含隐藏，用于管理页）
    @Published var allGroups: [BookGroup] = []

    func loadAllGroups() {
        let request: NSFetchRequest<BookGroup> = BookGroup.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(key: "order", ascending: true)]
        allGroups = (try? CoreDataStack.shared.viewContext.fetch(request)) ?? []
    }

    func createGroup(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let context = CoreDataStack.shared.viewContext
        let group = BookGroup.create(in: context, groupName: trimmed)
        group.order = Int32((allGroups.map { $0.order }.max() ?? 0) + 1)
        group.show = true

        try? CoreDataStack.shared.save()
        loadAllGroups()
        loadGroups()
        AppLogger.info("Bookshelf", "新建分组 \(trimmed)")
    }

    func renameGroup(_ group: BookGroup, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        group.groupName = trimmed
        try? CoreDataStack.shared.save()
        loadAllGroups()
        loadGroups()
    }

    /// 删除分组：同时把书籍上对应的位掩码清掉
    func deleteGroup(_ group: BookGroup) {
        let context = CoreDataStack.shared.viewContext
        let gid = group.groupId

        let request: NSFetchRequest<Book> = Book.fetchRequest()
        if let books = try? context.fetch(request) {
            for book in books where (book.group & gid) != 0 {
                book.group = book.group & ~gid
            }
        }

        context.delete(group)
        try? CoreDataStack.shared.save()

        loadAllGroups()
        loadGroups()
        Task { await loadBooks() }
        AppLogger.info("Bookshelf", "删除分组 \(group.groupName)")
    }

    func moveGroups(from source: IndexSet, to destination: Int) {
        var ordered = allGroups
        ordered.move(fromOffsets: source, toOffset: destination)

        for (index, group) in ordered.enumerated() {
            group.order = Int32(index)
        }
        try? CoreDataStack.shared.save()

        loadAllGroups()
        loadGroups()
    }

    func setVisible(_ group: BookGroup, visible: Bool) {
        group.show = visible
        try? CoreDataStack.shared.save()

        loadAllGroups()
        loadGroups()
        if selectedGroupId == group.groupId, !visible {
            selectGroup(nil)
        }
    }

    /// 分组内的书籍数量（位掩码语义，谓词表达不了，取全量后统计）
    func bookCount(for groupId: Int64) -> Int {
        let request: NSFetchRequest<Book> = Book.fetchRequest()
        let all = (try? CoreDataStack.shared.viewContext.fetch(request)) ?? []
        return all.filter { ($0.group & groupId) > 0 }.count
    }

    /// 读取可见分组（Android BookGroup.show + order）
    func loadGroups() {
        let request: NSFetchRequest<BookGroup> = BookGroup.fetchRequest()
        request.predicate = NSPredicate(format: "show == YES")
        request.sortDescriptors = [NSSortDescriptor(key: "order", ascending: true)]
        groups = (try? CoreDataStack.shared.viewContext.fetch(request)) ?? []
    }

    /// 按当前分组过滤（位掩码语义）
    private func applyGroupFilter(to books: [Book]) -> [Book] {
        guard let groupId = selectedGroupId else { return books }
        if groupId == BookGroup.allGroupId { return books }
        return books.filter { ($0.group & groupId) > 0 }
    }

    func refreshBooks() async {
        await loadBooks()
    }
    
    /// 批量删除（对齐 Android 批量管理的删除）
    func deleteBooks(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let context = CoreDataStack.shared.viewContext

        for book in books where ids.contains(book.bookId) {
            context.delete(book)
        }
        books.removeAll { ids.contains($0.bookId) }
        try? CoreDataStack.shared.save()
        AppLogger.info("Bookshelf", "批量删除 \(ids.count) 本")
    }

    /// 批量加入分组（Android add_to_group：位掩码 OR）
    func addBooks(ids: Set<UUID>, toGroup groupId: Int64) {
        guard !ids.isEmpty else { return }
        let context = CoreDataStack.shared.viewContext

        for book in books where ids.contains(book.bookId) {
            book.group = book.group | groupId
        }
        try? CoreDataStack.shared.save()
        Task { await loadBooks() }
        AppLogger.info("Bookshelf", "批量加入分组 \(ids.count) 本 → \(groupId)")
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