// 仅用于 Linux 上的类型检查：EPUB / PDF / MOBI / CBZ 解析器的桩。
// 真实实现在 Core/Parser/EPUBParser.swift 与 Core/Parser/LocalBookBinaryFormats.swift，
// 那两个文件依赖 UIKit / PDFKit / Compression，Linux 上无法编译，所以这里只保留签名。

import Foundation

final class EPUBParser {

    struct EPUBMetadata {
        let title: String
        let author: String
        let publisher: String?
        let language: String?
        let description: String?
        let rights: String?
        let date: String?
        let identifier: String?
    }

    struct EPUBChapter {
        let id: String
        let title: String
        let href: String
        let content: String
        let index: Int
        let mediaType: String
    }

    struct TOCItem {
        let title: String
        let href: String
        let level: Int
        let children: [TOCItem]
    }

    struct EPUBBook {
        let title: String
        let author: String
        let coverImage: Data?
        let chapters: [EPUBChapter]
        let metadata: EPUBMetadata
        let tableOfContents: [TOCItem]
    }

    static func parse(file url: URL) async throws -> EPUBBook {
        throw LocalBookParseError.emptyContent
    }
}

enum PdfTextParser {
    static func parse(url: URL, fallbackTitle: String) throws -> LocalBookParseResult {
        throw LocalBookParseError.emptyContent
    }
}

enum MobiParser {
    static func parse(url: URL, fallbackTitle: String) throws -> LocalBookParseResult {
        throw LocalBookParseError.emptyContent
    }
}

enum CbzParser {
    static func parse(url: URL, fallbackTitle: String) throws -> LocalBookParseResult {
        throw LocalBookParseError.emptyContent
    }
}
