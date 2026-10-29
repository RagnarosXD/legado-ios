//
//  UTType+EPUB.swift
//  Legado-iOS
//
//  UTType 扩展 - EPUB 文件类型支持
//

import UniformTypeIdentifiers

extension UTType {
    /// EPUB 文件类型
    static var epub: UTType {
        UTType(importedAs: "org.idpf.epub-container")
    }
    
    /// JSON 书源文件类型
    static var jsonSource: UTType {
        UTType(importedAs: "public.json")
    }

    /// MOBI / AZW3（Kindle 系）
    static var mobiBook: UTType {
        UTType(filenameExtension: "mobi") ?? UTType(importedAs: "com.mobipocket.mobi")
    }

    static var azw3Book: UTType {
        UTType(filenameExtension: "azw3") ?? .data
    }

    /// CBZ 漫画压缩包
    static var cbzComic: UTType {
        UTType(filenameExtension: "cbz") ?? UTType(importedAs: "com.legado.cbz-comic")
    }

    /// Markdown
    static var markdownText: UTType {
        UTType(filenameExtension: "md") ?? .plainText
    }

    /// 本地书籍导入支持的全部类型（1.1）
    static var localBookTypes: [UTType] {
        [.plainText, .epub, .pdf, .html, .markdownText, .mobiBook, .azw3Book, .cbzComic, .zip, .data]
    }
}