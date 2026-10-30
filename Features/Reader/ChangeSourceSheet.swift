//
//  ChangeSourceSheet.swift
//  Legado-iOS
//
//  换源面板：优先用上次搜索命中的书源缓存（SearchSourceCache），
//  需要时再手动触发一次并发搜索，避免每次换源都全量搜索几百个源。
//

import SwiftUI
import CoreData

// MARK: - 换源 ViewModel

@MainActor
final class ChangeSourceModel: ObservableObject {

    @Published var cachedHits: [CachedSourceHit] = []
    @Published var searchResults: [CachedSourceHit] = []
    @Published var isSearching = false
    @Published var isApplying = false
    @Published var completed = 0
    @Published var total = 0
    @Published var errorMessage: String?

    var progress: Double {
        guard total > 0 else { return 0 }
        return min(1, Double(completed) / Double(total))
    }

    func loadCache(for book: Book) {
        cachedHits = SearchSourceCache.shared.hits(name: book.name, author: book.author)
    }

    func source(for id: UUID) -> BookSource? {
        let context = CoreDataStack.shared.viewContext
        let request: NSFetchRequest<BookSource> = BookSource.fetchRequest()
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "sourceId == %@", id as CVarArg)
        return try? context.fetch(request).first
    }

    /// 重新搜索全部启用的文本源（并发 4），结果写回缓存
    func rescan(book: Book) async {
        guard !isSearching else { return }

        isSearching = true
        searchResults = []
        completed = 0

        let context = CoreDataStack.shared.viewContext
        let request: NSFetchRequest<BookSource> = BookSource.fetchRequest()
        request.predicate = NSPredicate(format: "enabled == YES AND searchUrl != nil")
        let all = (try? context.fetch(request)) ?? []
        let sources = all.filter { $0.supportsTextSearch }
        total = sources.count

        guard !sources.isEmpty else {
            errorMessage = "没有启用的文本书源"
            isSearching = false
            return
        }

        let keyword = book.name
        let limit = 4
        var pending = sources

        await withTaskGroup(of: (UUID, String, String, String?)?.self) { group in
            var running = 0

            while !pending.isEmpty || running > 0 {
                while running < limit, !pending.isEmpty {
                    let source = pending.removeFirst()
                    let sourceId = source.sourceId
                    let sourceName = source.bookSourceName

                    group.addTask {
                        do {
                            let results = try await WebBook.searchBook(source: source, key: keyword)
                            guard let match = results.first(where: {
                                $0.name.trimmingCharacters(in: .whitespaces).contains(keyword)
                            }) ?? results.first else { return nil }
                            return (sourceId, sourceName, match.bookUrl, match.coverUrl)
                        } catch {
                            return nil
                        }
                    }
                    running += 1
                }

                guard let value = await group.next() else { break }
                running -= 1
                completed += 1

                if let value {
                    let hit = CachedSourceHit(
                        sourceId: value.0,
                        sourceName: value.1,
                        sourceUrl: "",
                        bookUrl: value.2,
                        coverUrl: value.3,
                        intro: nil,
                        cachedAt: Date()
                    )
                    searchResults.append(hit)
                }
            }
        }

        if !searchResults.isEmpty {
            SearchSourceCache.shared.save(name: book.name, author: book.author, hits: searchResults)
            cachedHits = SearchSourceCache.shared.hits(name: book.name, author: book.author)
        }

        AppLogger.info("Source", "换源搜索完成 命中=\(searchResults.count) 总源=\(total)")
        isSearching = false
    }
}

// MARK: - 换源面板

struct ChangeSourceSheet: View {
    @Binding var isPresented: Bool
    let book: Book
    let onChanged: () -> Void

    @StateObject private var model = ChangeSourceModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                Section {
                    Button {
                        Task { await model.rescan(book: book) }
                    } label: {
                        HStack {
                            Label("重新搜索全部书源", systemImage: "arrow.clockwise")
                            Spacer()
                            if model.isSearching {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(model.isSearching)

                    if model.isSearching {
                        VStack(alignment: .leading, spacing: 6) {
                            ProgressView(value: model.progress)
                            Text("已搜索 \(model.completed)/\(model.total)，命中 \(model.searchResults.count) 个源")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                } footer: {
                    Text("换源优先使用上次搜索命中的书源，点一下直接切换，不需要重新搜索。")
                }

                if !model.cachedHits.isEmpty {
                    Section("上次搜索到的书源（\(model.cachedHits.count)）") {
                        ForEach(model.cachedHits) { hit in
                            Button {
                                apply(hit)
                            } label: {
                                hitRow(hit)
                            }
                            .disabled(model.isApplying)
                        }
                    }
                }

                if !model.searchResults.isEmpty {
                    Section("本次搜索命中（\(model.searchResults.count)）") {
                        ForEach(model.searchResults) { hit in
                            Button {
                                apply(hit)
                            } label: {
                                hitRow(hit)
                            }
                            .disabled(model.isApplying)
                        }
                    }
                }

                if !model.isSearching, model.cachedHits.isEmpty, model.searchResults.isEmpty {
                    EmptyStateView(
                        title: "还没有候选书源",
                        subtitle: "点上面的「重新搜索全部书源」",
                        imageName: "arrow.triangle.2.circlepath"
                    )
                }
            }
            .navigationTitle("换源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { dismiss() }
                }
            }
            .task {
                model.loadCache(for: book)
            }
            .alert("换源失败", isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )) {
                Button("确定", role: .cancel) { model.errorMessage = nil }
            } message: {
                Text(model.errorMessage ?? "")
            }
        }
    }

    // MARK: - 行

    private func hitRow(_ hit: CachedSourceHit) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(hit.sourceName)
                    .lineLimit(1)
                    .foregroundColor(.primary)

                if hit.sourceId.uuidString == book.origin {
                    Text("当前")
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.blue.opacity(0.15))
                        .foregroundColor(.blue)
                        .cornerRadius(3)
                }

                Spacer()

                Text(hit.ageDescription)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            if !hit.bookUrl.isEmpty {
                Text(hit.bookUrl)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
    }

    // MARK: - 应用

    private func apply(_ hit: CachedSourceHit) {
        guard !model.isApplying else { return }
        model.isApplying = true

        guard let source = model.source(for: hit.sourceId) else {
            model.errorMessage = "该书源已被删除，请重新搜索"
            model.isApplying = false
            return
        }

        let context = CoreDataStack.shared.viewContext

        // bookUrl 变了，旧章节地址失效，先清掉
        let chapterRequest = BookChapter.fetchRequest(byBookId: book.bookId)
        if let chapters = try? context.fetch(chapterRequest) {
            for chapter in chapters {
                context.delete(chapter)
            }
        }

        BookSourceResolver.switchBook(book, to: source, bookUrl: hit.bookUrl, in: context)
        AppLogger.info("Source", "换源 \(book.name) → \(hit.sourceName)")

        model.isApplying = false
        isPresented = false
        dismiss()
        onChanged()
    }
}
