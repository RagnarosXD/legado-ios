//
//  BookSourceResolver.swift
//  Legado-iOS
//
//  统一解析「这本书该用哪个书源」
//  书籍与书源的关系有多条线索：source 关系、origin(sourceId)、旧版 origin(URL)、originName(源名)，
//  之前各处以 UUID(uuidString:) 单条路径取源，源被删或旧数据格式不同就直接报「未找到书源」。
//

import Foundation
import CoreData

enum BookSourceResolver {

    /// 依次尝试：关系 → origin 当 sourceId → origin 当 URL → 源名匹配
    static func resolve(for book: Book, in context: NSManagedObjectContext) -> BookSource? {
        if let source = book.source, !source.isDeleted {
            return source
        }

        if let uuid = UUID(uuidString: book.origin) {
            if let source = fetch(BookSource.self, in: context, predicate: NSPredicate(format: "sourceId == %@", uuid as CVarArg)) {
                book.source = source
                return source
            }
        }

        if book.origin.contains("://") {
            if let source = fetch(BookSource.self, in: context, predicate: NSPredicate(format: "bookSourceUrl == %@", book.origin)) {
                book.source = source
                return source
            }
        }

        if !book.originName.isEmpty {
            if let source = fetch(BookSource.self, in: context, predicate: NSPredicate(format: "bookSourceName == %@", book.originName)) {
                book.source = source
                return source
            }
        }

        return nil
    }

    private static func fetch<T: NSManagedObject>(
        _ type: T.Type,
        in context: NSManagedObjectContext,
        predicate: NSPredicate
    ) -> T? {
        let request = NSFetchRequest<T>(entityName: String(describing: T.self))
        request.fetchLimit = 1
        request.predicate = predicate
        return try? context.fetch(request).first
    }

    /// 把书籍切换到指定书源（换源）
    static func switchBook(
        _ book: Book,
        to source: BookSource,
        bookUrl: String,
        in context: NSManagedObjectContext
    ) {
        book.source = source
        book.origin = source.sourceId.uuidString
        book.originName = source.bookSourceName
        book.bookUrl = bookUrl
        book.tocUrl = ""
        book.durChapterIndex = 0
        book.durChapterTitle = ""
        book.durChapterPos = 0
        book.durChapterTime = Date()
        try? context.save()
    }
}
