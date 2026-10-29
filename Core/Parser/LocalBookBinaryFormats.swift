//
//  LocalBookBinaryFormats.swift
//  Legado-iOS
//
//  二进制/容器类本地书籍解析：PDF、MOBI/AZW3、CBZ（含 zip + deflate 解压）
//

import Foundation
import Compression
import PDFKit
import UIKit

// MARK: - deflate

enum Inflate {

    /// 原始 deflate 流（zip 内部使用）
    static func raw(_ data: Data) -> Data? {
        guard !data.isEmpty else { return Data() }

        let chunkSize = 64 * 1024
        let dstBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        let srcPlaceholder = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        defer {
            dstBuffer.deallocate()
            srcPlaceholder.deallocate()
        }

        var stream = compression_stream(
            dst_ptr: dstBuffer,
            dst_size: chunkSize,
            src_ptr: UnsafePointer(srcPlaceholder),
            src_size: 0,
            state: nil
        )
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            return nil
        }
        defer { compression_stream_destroy(&stream) }

        var output = Data()
        let result: Data? = data.withUnsafeBytes { rawBuffer -> Data? in
            guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return nil }
            stream.src_ptr = base
            stream.src_size = data.count

            while true {
                stream.dst_ptr = dstBuffer
                stream.dst_size = chunkSize
                let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = chunkSize - stream.dst_size
                if produced > 0 {
                    output.append(dstBuffer, count: produced)
                }
                if status == COMPRESSION_STATUS_ERROR { return nil }
                if status == COMPRESSION_STATUS_END { break }
                if stream.src_size == 0 && produced == 0 { break }
            }
            return output
        }

        return result
    }

    /// zlib 包装流（RFC1950，前 2 字节头）
    static func zlib(_ data: Data) -> Data? {
        guard data.count > 6 else { return nil }
        return raw(data.dropFirst(2))
    }
}

// MARK: - ZIP

struct ZipEntry {
    let name: String
    let method: UInt16
    let compressedSize: Int
    let uncompressedSize: Int
    let localHeaderOffset: Int
}

enum ZipArchive {

    static func entries(in data: Data) -> [ZipEntry] {
        guard let eocd = findEOCD(data) else { return [] }
        guard let total = data.beUInt16(eocd + 10),
              let cdOffset32 = data.beUInt32(eocd + 16) else { return [] }

        var offset = Int(cdOffset32)
        var result: [ZipEntry] = []
        let limit = min(Int(total), 20000)

        for _ in 0..<limit {
            guard let signature = data.beUInt32(offset), signature == 0x02014B50 else { break }
            guard let method = data.beUInt16(offset + 10),
                  let compressed = data.beUInt32(offset + 20),
                  let uncompressed = data.beUInt32(offset + 24),
                  let nameLength = data.beUInt16(offset + 28),
                  let extraLength = data.beUInt16(offset + 30),
                  let commentLength = data.beUInt16(offset + 32),
                  let localOffset = data.beUInt32(offset + 42) else { break }

            let nameStart = offset + 46
            let nameEnd = nameStart + Int(nameLength)
            guard nameEnd <= data.count else { break }
            let nameData = data.subdata(in: (data.startIndex + nameStart)..<(data.startIndex + nameEnd))
            let name = String(data: nameData, encoding: .utf8) ?? ""

            result.append(ZipEntry(
                name: name,
                method: method,
                compressedSize: Int(compressed),
                uncompressedSize: Int(uncompressed),
                localHeaderOffset: Int(localOffset)
            ))

            offset = nameEnd + Int(extraLength) + Int(commentLength)
        }

        return result
    }

    static func extract(_ entry: ZipEntry, from data: Data) -> Data? {
        let header = entry.localHeaderOffset
        guard let signature = data.beUInt32(header), signature == 0x04034B50,
              let nameLength = data.beUInt16(header + 26),
              let extraLength = data.beUInt16(header + 28) else { return nil }

        let start = header + 30 + Int(nameLength) + Int(extraLength)
        let end = start + entry.compressedSize
        guard start >= 0, end <= data.count, start < end else { return nil }
        let payload = data.subdata(in: (data.startIndex + start)..<(data.startIndex + end))

        switch entry.method {
        case 0:
            return payload
        case 8:
            return Inflate.raw(payload)
        default:
            return nil
        }
    }

    private static func findEOCD(_ data: Data) -> Int? {
        let signature: [UInt8] = [0x50, 0x4B, 0x05, 0x06]
        guard data.count > 22 else { return nil }
        let lowerBound = max(0, data.count - 66_000)
        var index = data.count - 22
        while index >= lowerBound {
            let base = data.startIndex + index
            if data[base] == signature[0],
               data[base + 1] == signature[1],
               data[base + 2] == signature[2],
               data[base + 3] == signature[3] {
                return index
            }
            index -= 1
        }
        return nil
    }
}

// MARK: - CBZ（图片漫画）

enum CbzParser {

    static func parse(url: URL, fallbackTitle: String) throws -> LocalBookParseResult {
        let data = try Data(contentsOf: url)
        let entries = ZipArchive.entries(in: data)
        guard !entries.isEmpty else {
            throw LocalBookParseError.corrupted("不是有效的 zip 容器")
        }

        let images = entries
            .filter { !$0.name.hasPrefix("__MACOSX") && isImage($0.name) && $0.uncompressedSize > 0 }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        guard !images.isEmpty else {
            throw LocalBookParseError.unavailable("压缩包里没有找到图片（CBZ 应包含 jpg/png/webp）")
        }

        let directory = try imageDirectory(for: fallbackTitle)
        var paths: [String] = []

        for (index, entry) in images.enumerated() {
            guard let imageData = ZipArchive.extract(entry, from: data), !imageData.isEmpty else { continue }
            let ext = (entry.name as NSString).pathExtension.lowercased()
            let suffix = ext.isEmpty ? "jpg" : ext
            let target = directory.appendingPathComponent(String(format: "%04d.%@", index + 1, suffix))
            try? imageData.write(to: target, options: .atomic)
            if FileManager.default.fileExists(atPath: target.path) {
                paths.append(target.path)
            }
        }

        guard !paths.isEmpty else {
            throw LocalBookParseError.corrupted("图片解压失败")
        }

        // 每页一章：阅读器识别 __images__ 标记后走图片模式
        let chapters = paths.enumerated().map { index, path in
            LocalChapter(
                title: "第 \(index + 1) 页",
                content: LocalChapter.imagesMarker + "\n" + path,
                href: String(index)
            )
        }

        let cover = firstImageData(paths: paths)

        return LocalBookParseResult(
            format: .cbz,
            title: fallbackTitle,
            author: "未知",
            intro: "漫画，共 \(paths.count) 页",
            coverData: cover,
            chapters: chapters
        )
    }

    private static func imageDirectory(for title: String) throws -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let safeName = title.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        let directory = documents
            .appendingPathComponent("Manga", isDirectory: true)
            .appendingPathComponent(safeName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func firstImageData(paths: [String]) -> Data? {
        guard let first = paths.first else { return nil }
        return try? Data(contentsOf: URL(fileURLWithPath: first))
    }

    private static func isImage(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return ["jpg", "jpeg", "png", "webp", "gif", "bmp"].contains(ext)
    }
}

// MARK: - PDF

enum PdfTextParser {

    static func parse(url: URL, fallbackTitle: String) throws -> LocalBookParseResult {
        guard let document = PDFDocument(url: url) else {
            throw LocalBookParseError.corrupted("PDF 无法打开")
        }
        if document.isEncrypted && document.isLocked {
            throw LocalBookParseError.drmProtected
        }

        let pageCount = document.pageCount
        guard pageCount > 0 else { throw LocalBookParseError.emptyContent }

        let groupSize = 8
        var chapters: [LocalChapter] = []
        var buffer: [String] = []
        var groupStart = 1

        func flush(endPage: Int) {
            let content = buffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            buffer.removeAll()
            guard !content.isEmpty else { return }
            let title = groupStart == endPage
                ? "第 \(groupStart) 页"
                : "第 \(groupStart)-\(endPage) 页"
            chapters.append(LocalChapter(title: title, content: content, href: String(chapters.count)))
        }

        for index in 0..<pageCount {
            if let page = document.page(at: index), let text = page.string, !text.isEmpty {
                buffer.append(text)
            }
            if buffer.count >= groupSize {
                flush(endPage: index + 1)
                groupStart = index + 2
            }
        }
        if !buffer.isEmpty {
            flush(endPage: pageCount)
        }

        guard !chapters.isEmpty else {
            throw LocalBookParseError.unavailable("这个 PDF 没有可提取的文字（可能是扫描版），暂不支持 OCR")
        }

        var intro: String?
        if let first = document.page(at: 0)?.string {
            let trimmed = first.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { intro = String(trimmed.prefix(120)) }
        }

        return LocalBookParseResult(
            format: .pdf,
            title: fallbackTitle,
            author: "未知",
            intro: intro,
            coverData: thumbnail(document: document),
            chapters: chapters
        )
    }

    private static func thumbnail(document: PDFDocument) -> Data? {
        guard let page = document.page(at: 0) else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 1, bounds.height > 1 else { return nil }

        let targetWidth: CGFloat = 300
        let scale = targetWidth / bounds.width
        let size = CGSize(width: targetWidth, height: bounds.height * scale)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            context.cgContext.saveGState()
            context.cgContext.translateBy(x: 0, y: size.height)
            context.cgContext.scaleBy(x: scale, y: -scale)
            page.draw(with: .mediaBox, to: context.cgContext)
            context.cgContext.restoreGState()
        }
        return image.jpegData(compressionQuality: 0.8)
    }
}

// MARK: - MOBI / AZW3

enum MobiParser {

    static func parse(url: URL, fallbackTitle: String) throws -> LocalBookParseResult {
        let data = try Data(contentsOf: url)
        guard data.count > 128,
              let recordCount = data.beUInt16(0x4C), recordCount > 1 else {
            throw LocalBookParseError.corrupted("不是有效的 MOBI 文件")
        }

        var offsets: [Int] = []
        offsets.reserveCapacity(Int(recordCount) + 1)
        for index in 0...Int(recordCount) {
            guard let value = data.beUInt32(0x4E + index * 4) else {
                throw LocalBookParseError.corrupted("记录偏移表损坏")
            }
            offsets.append(Int(value))
        }

        guard let record0 = slice(data, offsets[0], offsets[1]) else {
            throw LocalBookParseError.corrupted("首个记录损坏")
        }
        guard let compression = record0.beUInt16(0),
              let textRecordCount = record0.beUInt16(8) else {
            throw LocalBookParseError.corrupted("PalmDOC 头损坏")
        }
        let encryption = record0.beUInt16(12) ?? 0
        guard encryption == 0 else { throw LocalBookParseError.drmProtected }

        // MOBI header
        let mobiOffset = 16
        var title = fallbackTitle
        var author = "未知"

        if let magic = record0.beUInt32(mobiOffset), magic == 0x4D4F4249 {
            let headerLength = Int(record0.beUInt32(mobiOffset + 4) ?? 0)

            if let nameOffset = record0.beUInt32(mobiOffset + 0x44),
               let nameLength = record0.beUInt32(mobiOffset + 0x48),
               let nameData = slice(record0, Int(nameOffset), Int(nameOffset) + Int(nameLength)),
               let name = String(data: nameData, encoding: .utf8),
               !name.isEmpty {
                title = name
            }

            // EXTH
            let exthOffset = mobiOffset + headerLength
            if let exthMagic = record0.beUInt32(exthOffset), exthMagic == 0x45585448,
               let exthCount = record0.beUInt32(exthOffset + 8) {
                var cursor = exthOffset + 12
                for _ in 0..<Int(exthCount) {
                    guard let type = record0.beUInt32(cursor),
                          let length = record0.beUInt32(cursor + 4),
                          length >= 8,
                          cursor + Int(length) <= record0.count else { break }
                    if type == 100,
                       let value = slice(record0, cursor + 8, cursor + Int(length)),
                       let text = String(data: value, encoding: .utf8),
                       !text.isEmpty {
                        author = text
                    }
                    cursor += Int(length)
                }
            }
        }

        // 正文记录
        var htmlData = Data()
        let textRecords = min(Int(textRecordCount), max(0, offsets.count - 2))
        for index in 0..<textRecords {
            guard let chunk = slice(data, offsets[1 + index], offsets[2 + index]) else { continue }
            switch compression {
            case 1:
                htmlData.append(chunk)
            case 2:
                guard let inflated = PalmDoc.decompress(chunk) else {
                    throw LocalBookParseError.corrupted("PalmDOC 解压失败")
                }
                htmlData.append(inflated)
            default:
                throw LocalBookParseError.unavailable("MOBI 使用了 HUFF/CDIC 压缩，暂不支持；请用 Calibre 转成 EPUB 再导入")
            }
        }

        guard !htmlData.isEmpty else { throw LocalBookParseError.emptyContent }

        let html = String(data: htmlData, encoding: .utf8)
            ?? String(data: htmlData, encoding: TextFileDecoder.gb18030)
            ?? ""

        // MOBI 内部分页标记先转成标题分隔
        var prepared = html
            .replacingOccurrences(of: "(?i)<mbp:pagebreak\\s*/?>", with: "<h2>分页</h2>", options: .regularExpression)
        if prepared.range(of: "(?i)<h[1-3]", options: .regularExpression) == nil {
            prepared = "<h2>正文</h2>" + prepared
        }

        var chapters = ChapterSplitter.splitHTML(prepared, fallbackTitle: fallbackTitle)

        // 分页标记产生的"分页"标题没有意义，合并回上一章
        chapters = mergePlaceholderChapters(chapters)
        guard !chapters.isEmpty else { throw LocalBookParseError.emptyContent }

        return LocalBookParseResult(
            format: url.pathExtension.lowercased() == "mobi" ? .mobi : .azw3,
            title: title,
            author: author,
            intro: nil,
            coverData: nil,
            chapters: chapters
        )
    }

    private static func mergePlaceholderChapters(_ chapters: [LocalChapter]) -> [LocalChapter] {
        var result: [LocalChapter] = []
        for chapter in chapters {
            if chapter.title == "分页", var last = result.last {
                last.content += "\n" + chapter.content
                result[result.count - 1] = last
            } else {
                result.append(chapter)
            }
        }
        return result
    }

    private static func slice(_ data: Data, _ start: Int, _ end: Int) -> Data? {
        guard start >= 0, end > start, end <= data.count else { return nil }
        return data.subdata(in: (data.startIndex + start)..<(data.startIndex + end))
    }
}

// MARK: - PalmDOC 解压

enum PalmDoc {

    static func decompress(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count * 4)

        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            index += 1

            if byte == 0 {
                guard index < bytes.count else { break }
                output.append(bytes[index])
                index += 1
            } else if byte <= 8 {
                let count = Int(byte)
                guard index + count <= bytes.count else { break }
                output.append(contentsOf: bytes[index..<(index + count)])
                index += count
            } else if byte < 0x80 {
                output.append(byte)
            } else if byte >= 0xC0 {
                output.append(0x20)
                output.append(byte ^ 0x80)
            } else {
                guard index < bytes.count else { break }
                let next = bytes[index]
                index += 1
                let combined = (Int(byte) << 8) | Int(next)
                let distance = (combined >> 3) & 0x7FF
                let length = (combined & 0x7) + 3
                guard distance > 0, distance <= output.count else { return nil }
                let start = output.count - distance
                for offset in 0..<length {
                    let source = start + offset
                    guard source < output.count else { break }
                    output.append(output[source])
                }
            }
        }

        return Data(output)
    }
}

// MARK: - Data 读取

extension Data {
    func beUInt16(_ offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= count else { return nil }
        let base = startIndex + offset
        return (UInt16(self[base]) << 8) | UInt16(self[base + 1])
    }

    func beUInt32(_ offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        let base = startIndex + offset
        return (UInt32(self[base]) << 24)
            | (UInt32(self[base + 1]) << 16)
            | (UInt32(self[base + 2]) << 8)
            | UInt32(self[base + 3])
    }
}
