//
//  LocalBookViewModel.swift
//  Legado-iOS
//
//  本地书籍 ViewModel
//

import Foundation
import CoreData
import SwiftUI
import UniformTypeIdentifiers

@MainActor
class LocalBookViewModel: ObservableObject {
    @Published var localBooks: [Book] = []
    @Published var isImporting = false
    @Published var errorMessage: String?
    @Published var successMessage: String?
    
    // MARK: - 导入本地书籍

    /// 支持 TXT / EPUB / PDF / MOBI / AZW3 / HTML / Markdown / CBZ
    func importBook(url: URL) async throws -> Book {
        isImporting = true
        defer { isImporting = false }

        do {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }

            let result = try await LocalBookParser.parse(url: url)
            let context = CoreDataStack.shared.viewContext
            let fileName = url.lastPathComponent

            let book = Book.create(in: context)
            book.name = result.title.isEmpty ? (fileName as NSString).deletingPathExtension : result.title
            book.author = result.author.isEmpty ? "未知" : result.author
            book.type = result.format.isImageBased ? 2 : (result.format == .epub ? 1 : 0)
            book.origin = "local"
            book.originName = fileName
            book.bookUrl = url.path
            book.tocUrl = ""
            book.canUpdate = false
            book.totalChapterNum = Int32(result.chapters.count)
            if let intro = result.intro, !intro.isEmpty {
                book.intro = intro
            }

            if let coverData = result.coverData {
                let coverURL = try await saveCoverImage(coverData, bookId: book.bookId)
                book.coverUrl = coverURL.path
            }

            let chapterDirectory = try chapterDirectory(for: book.bookId)

            for (index, chapter) in result.chapters.enumerated() {
                let record = BookChapter.create(
                    in: context,
                    bookId: book.bookId,
                    url: chapter.href.isEmpty ? String(index) : chapter.href,
                    index: Int32(index),
                    title: chapter.title
                )
                record.book = book
                record.wordCount = Int32(chapter.content.count)
                record.isCached = true

                // 正文落盘为单章缓存文件，阅读时直接命中，避免每次翻页重新解析整本
                let chapterFile = chapterDirectory.appendingPathComponent(String(format: "%05d.txt", index))
                do {
                    try chapter.content.write(to: chapterFile, atomically: true, encoding: .utf8)
                    record.cachePath = chapterFile.path
                } catch {
                    record.cachePath = nil
                }
            }

            if context.hasChanges {
                try context.save()
            }

            successMessage = "导入成功：\(book.name)（\(result.format.displayName)，\(result.chapters.count) 章）"
            return book
        } catch {
            errorMessage = "导入失败：\(error.localizedDescription)"
            throw error
        }
    }

    private func chapterDirectory(for bookId: UUID) throws -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let directory = documents
            .appendingPathComponent("LocalChapters", isDirectory: true)
            .appendingPathComponent(bookId.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    
    // MARK: - 加载本地书籍
    func loadLocalBooks() async {
        do {
            let request: NSFetchRequest<Book> = Book.fetchRequest()
            request.predicate = NSPredicate(format: "origin == 'local'")
            request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
            
            localBooks = try CoreDataStack.shared.viewContext.fetch(request)
        } catch {
            errorMessage = "加载失败：\(error.localizedDescription)"
        }
    }
    
    // MARK: - 旧的分章实现已由 LocalBookParser 统一接管
    
    // MARK: - 编码检测与分章：见 Core/Parser/LocalBookParser.swift
    
    // MARK: - 保存封面图片
    private func saveCoverImage(_ data: Data, bookId: UUID) async throws -> URL {
        let fileManager = FileManager.default
        let documentsPath = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let bookDir = documentsPath.appendingPathComponent("covers", isDirectory: true)
        
        if !fileManager.fileExists(atPath: bookDir.path) {
            try fileManager.createDirectory(at: bookDir, withIntermediateDirectories: true)
        }
        
        let coverURL = bookDir.appendingPathComponent("\(bookId.uuidString).jpg")
        try data.write(to: coverURL)
        
        return coverURL
    }
    
    // MARK: - 删除本地书籍
    func deleteBook(_ book: Book) {
        // 删除书籍原文件与章节缓存
        if book.origin == "local" {
            try? FileManager.default.removeItem(atPath: book.bookUrl)

            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let chapterDir = documents
                .appendingPathComponent("LocalChapters", isDirectory: true)
                .appendingPathComponent(book.bookId.uuidString, isDirectory: true)
            try? FileManager.default.removeItem(at: chapterDir)
        }

        CoreDataStack.shared.viewContext.delete(book)
        try? CoreDataStack.shared.save()

        Task {
            await loadLocalBooks()
        }
    }
}

// MARK: - 错误类型
enum LocalBookError: LocalizedError {
    case unsupportedFormat
    case fileNotFound
    case parseFailed
    case notImplemented
    
    var errorDescription: String? {
        switch self {
        case .unsupportedFormat: return "不支持的文件格式"
        case .fileNotFound: return "文件不存在"
        case .parseFailed: return "解析失败"
        case .notImplemented: return "功能尚未实现"
        }
    }
}

// MARK: - 本地书籍视图
struct LocalBookView: View {
    @StateObject private var viewModel = LocalBookViewModel()
    var onImportTapped: () -> Void
    
    var body: some View {
        Group {
            if viewModel.localBooks.isEmpty {
                EmptyStateView(
                    title: "暂无本地书籍",
                    subtitle: "支持 TXT / EPUB / PDF / MOBI / AZW3 / HTML / Markdown / CBZ",
                    imageName: "book.closed"
                )
            } else {
                List {
                    ForEach(viewModel.localBooks, id: \.bookId) { book in
                        HStack {
                            BookCoverView(url: book.coverUrl)
                                .frame(width: 50, height: 70)
                                .background(Color.gray.opacity(0.1))
                                .cornerRadius(4)
                            
                            VStack(alignment: .leading) {
                                Text(book.name)
                                    .font(.body)
                                    .fontWeight(.medium)
                                
                                Text("\(book.totalChapterNum) 章")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                
                                Text(book.originName ?? "")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            
                            Spacer()
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                viewModel.deleteBook(book)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("本地书籍")
        .toolbar {
            ToolbarItem {
                Button(action: onImportTapped) {
                    if viewModel.isImporting {
                        ProgressView()
                    } else {
                        Label("导入", systemImage: "plus")
                    }
                }
                .disabled(viewModel.isImporting)
            }
        }
        .task {
            await viewModel.loadLocalBooks()
        }
    }
}