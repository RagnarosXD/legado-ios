//
//  LocalBookParser.swift
//  Legado-iOS
//
//  本地书籍统一解析入口
//  - 文本类：TXT（多编码）、HTML/XHTML、Markdown
//  - 容器类：EPUB（复用 EPUBParser）、PDF、MOBI/AZW3、CBZ（图片）
//  - 结构识别后统一产出「书名 / 作者 / 封面 / 章节列表」
//

import Foundation

// MARK: - 格式

enum LocalBookFormat: String, CaseIterable {
    case txt
    case epub
    case pdf
    case mobi
    case azw3
    case html
    case markdown
    case cbz

    init?(url: URL) {
        switch url.pathExtension.lowercased() {
        case "txt", "text":
            self = .txt
        case "epub":
            self = .epub
        case "pdf":
            self = .pdf
        case "mobi":
            self = .mobi
        case "azw3", "azw":
            self = .azw3
        case "html", "htm", "xhtml":
            self = .html
        case "md", "markdown":
            self = .markdown
        case "cbz":
            self = .cbz
        default:
            return nil
        }
    }

    var displayName: String {
        switch self {
        case .txt: return "TXT"
        case .epub: return "EPUB"
        case .pdf: return "PDF"
        case .mobi: return "MOBI"
        case .azw3: return "AZW3"
        case .html: return "HTML"
        case .markdown: return "Markdown"
        case .cbz: return "CBZ 漫画"
        }
    }

    /// 是否是图片类（阅读器需要走图片模式）
    var isImageBased: Bool {
        self == .cbz
    }

    static var supportedExtensions: [String] {
        ["txt", "epub", "pdf", "mobi", "azw3", "azw", "html", "htm", "xhtml", "md", "markdown", "cbz"]
    }

    static var supportedUTTypeIdentifiers: [String] {
        ["public.plain-text", "org.idpf.epub-container", "com.adobe.pdf", "public.html",
         "net.daringfireball.markdown", "public.zip-archive"]
    }
}

// MARK: - 解析结果

struct LocalChapter {
    /// 图片章节标记：content 以此开头时，后续每行是一个图片文件的绝对路径
    static let imagesMarker = "__images__"

    var title: String
    var content: String
    var href: String
}

struct LocalBookParseResult {
    var format: LocalBookFormat
    var title: String
    var author: String
    var intro: String?
    var coverData: Data?
    var chapters: [LocalChapter]
}

enum LocalBookParseError: LocalizedError {
    case unsupportedFormat(String)
    case emptyContent
    case corrupted(String)
    case drmProtected
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let ext): return "暂不支持 .\(ext) 格式"
        case .emptyContent: return "没有解析到正文内容"
        case .corrupted(let detail): return "文件损坏或格式异常：\(detail)"
        case .drmProtected: return "文件受 DRM 保护，无法解析"
        case .unavailable(let detail): return detail
        }
    }
}

// MARK: - 统一入口

enum LocalBookParser {

    static func parse(url: URL) async throws -> LocalBookParseResult {
        guard let format = LocalBookFormat(url: url) else {
            throw LocalBookParseError.unsupportedFormat(url.pathExtension)
        }

        let fallbackTitle = url.deletingPathExtension().lastPathComponent

        switch format {
        case .txt:
            let data = try Data(contentsOf: url)
            let text = try TextFileDecoder.decode(data).text
            let chapters = ChapterSplitter.splitPlainText(text, fallbackTitle: fallbackTitle)
            guard !chapters.isEmpty else { throw LocalBookParseError.emptyContent }
            return LocalBookParseResult(
                format: format,
                title: fallbackTitle,
                author: "未知",
                intro: nil,
                coverData: nil,
                chapters: chapters
            )

        case .html:
            let data = try Data(contentsOf: url)
            let html = try TextFileDecoder.decode(data).text
            let chapters = ChapterSplitter.splitHTML(html, fallbackTitle: fallbackTitle)
            guard !chapters.isEmpty else { throw LocalBookParseError.emptyContent }
            return LocalBookParseResult(
                format: format, title: fallbackTitle, author: "未知",
                intro: nil, coverData: nil, chapters: chapters
            )

        case .markdown:
            let data = try Data(contentsOf: url)
            let text = try TextFileDecoder.decode(data).text
            let chapters = ChapterSplitter.splitMarkdown(text, fallbackTitle: fallbackTitle)
            guard !chapters.isEmpty else { throw LocalBookParseError.emptyContent }
            return LocalBookParseResult(
                format: format, title: fallbackTitle, author: "未知",
                intro: nil, coverData: nil, chapters: chapters
            )

        case .epub:
            let epub = try await EPUBParser.parse(file: url)
            let chapters = epub.chapters.map {
                LocalChapter(title: $0.title, content: $0.content, href: $0.href)
            }
            guard !chapters.isEmpty else { throw LocalBookParseError.emptyContent }
            return LocalBookParseResult(
                format: format,
                title: epub.title.isEmpty ? fallbackTitle : epub.title,
                author: epub.author.isEmpty ? "未知" : epub.author,
                intro: epub.metadata.description,
                coverData: epub.coverImage,
                chapters: chapters
            )

        case .pdf:
            return try PdfTextParser.parse(url: url, fallbackTitle: fallbackTitle)

        case .mobi, .azw3:
            return try MobiParser.parse(url: url, fallbackTitle: fallbackTitle)

        case .cbz:
            return try CbzParser.parse(url: url, fallbackTitle: fallbackTitle)
        }
    }
}

// MARK: - 文本解码

enum TextFileDecoder {

    /// GB18030 / Big5 的 NSStringEncoding 值（跨平台常量，避免依赖 CFStringEncodings）
    static let gb18030 = String.Encoding(rawValue: 0x80000632)
    static let big5 = String.Encoding(rawValue: 0x80000A03)

    struct Result {
        let text: String
        let encoding: String.Encoding
    }

    static func decode(_ data: Data) throws -> Result {
        guard !data.isEmpty else { throw LocalBookParseError.emptyContent }

        if let (encoding, skip) = bomEncoding(data) {
            let body = data.dropFirst(skip)
            if let text = String(data: body, encoding: encoding) {
                return Result(text: sanitize(text), encoding: encoding)
            }
        }

        // 先用 UTF-8 严格解码（非法序列会失败，避免中文被错误识别）
        if let text = String(data: data, encoding: .utf8) {
            return Result(text: sanitize(text), encoding: .utf8)
        }

        // 再看是不是 UTF-16（无 BOM 时按零字节密度猜）
        if let guess = guessUTF16(data), let text = String(data: data, encoding: guess) {
            return Result(text: sanitize(text), encoding: guess)
        }

        // 中文常见编码
        for encoding in [gb18030, big5, .utf16LittleEndian, .utf16BigEndian, .isoLatin1] {
            if let text = String(data: data, encoding: encoding), !text.isEmpty {
                return Result(text: sanitize(text), encoding: encoding)
            }
        }

        throw LocalBookParseError.unavailable("无法识别文件编码，请另存为 UTF-8 后重试")
    }

    private static func bomEncoding(_ data: Data) -> (String.Encoding, Int)? {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { return (.utf8, 3) }
        if data.starts(with: [0xFF, 0xFE]) { return (.utf16LittleEndian, 2) }
        if data.starts(with: [0xFE, 0xFF]) { return (.utf16BigEndian, 2) }
        return nil
    }

    private static func guessUTF16(_ data: Data) -> String.Encoding? {
        let sample = data.prefix(2048)
        guard sample.count > 8 else { return nil }
        var zeroEven = 0
        var zeroOdd = 0
        for (index, byte) in sample.enumerated() {
            if byte == 0 {
                if index % 2 == 0 { zeroEven += 1 } else { zeroOdd += 1 }
            }
        }
        let half = sample.count / 2
        if zeroOdd > half / 3 && zeroEven < half / 10 { return .utf16LittleEndian }
        if zeroEven > half / 3 && zeroOdd < half / 10 { return .utf16BigEndian }
        return nil
    }

    /// 去掉 BOM、控制字符，统一换行
    static func sanitize(_ text: String) -> String {
        var result = text
        if result.hasPrefix("\u{FEFF}") {
            result.removeFirst()
        }
        result = result.replacingOccurrences(of: "\r\n", with: "\n")
        result = result.replacingOccurrences(of: "\r", with: "\n")
        result = result.replacingOccurrences(of: "\u{0000}", with: "")
        return result
    }
}

// MARK: - 分章

enum ChapterSplitter {

    /// 常见章节标题：第X章/回/节/卷…、Chapter N、序章/楔子、番外 等
    private static let chapterPatterns: [String] = [
        "^\\s{0,4}第\\s*[0-9０-９零一二三四五六七八九十百千万两]{1,8}\\s*[章回节卷集部篇幕](?:[\\s　:：、.·-].{0,26})?$",
        "^\\s{0,4}(?:Chapter|CHAPTER|chapter)\\s{1,3}[0-9IVXLCivxlc]{1,6}\\b.{0,26}$",
        "^\\s{0,4}(?:序章|序言|楔子|引子|前言|引言|后记|尾声|终章|大结局|番外|附录)\\s*.{0,26}$",
        "^\\s{0,4}(?:正文\\s*)?第\\s*[0-9０-９]{1,5}\\s*(?:章|节|回)\\s*.{0,26}$"
    ]

    private static let compiledPatterns: [NSRegularExpression] = chapterPatterns.compactMap {
        try? NSRegularExpression(pattern: $0)
    }

    /// 纯文本分章（TXT）
    static func splitPlainText(_ rawText: String, fallbackTitle: String) -> [LocalChapter] {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }

        let lines = text.components(separatedBy: "\n")
        var chapters: [LocalChapter] = []
        var currentTitle: String = fallbackTitle
        var buffer: [String] = []
        var hasRealHeading = false

        func flush() {
            let content = buffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { return }
            chapters.append(LocalChapter(
                title: currentTitle,
                content: content,
                href: String(chapters.count)
            ))
        }

        for line in lines {
            let candidate = line.trimmingCharacters(in: .whitespaces)
            if isChapterHeading(candidate) {
                flush()
                buffer.removeAll()
                currentTitle = candidate.isEmpty ? "第\(chapters.count + 1)章" : candidate
                hasRealHeading = true
            } else {
                buffer.append(line)
            }
        }
        flush()

        // 一个标题都没识别到：按固定长度切块，避免整本变成一页
        if !hasRealHeading || chapters.count <= 1 {
            let single = chapters.first?.content ?? text
            let chunks = splitByLength(single, chunkSize: 12000)
            if chunks.count > 1 {
                return chunks.enumerated().map { index, chunk in
                    LocalChapter(title: "第\(index + 1)节", content: chunk, href: String(index))
                }
            }
        }

        if chapters.isEmpty {
            return [LocalChapter(title: fallbackTitle, content: text, href: "0")]
        }
        return chapters
    }

    private static func isChapterHeading(_ line: String) -> Bool {
        guard !line.isEmpty, line.count <= 40 else { return false }
        let range = NSRange(line.startIndex..., in: line)
        for regex in compiledPatterns where regex.firstMatch(in: line, range: range) != nil {
            return true
        }
        return false
    }

    /// HTML 分章：按 h1~h3 切
    static func splitHTML(_ html: String, fallbackTitle: String) -> [LocalChapter] {
        let pattern = "(?is)<h([1-3])[^>]*>(.*?)</h\\1>"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            let text = HTMLTextExtractor.plainText(from: html)
            return text.isEmpty ? [] : [LocalChapter(title: fallbackTitle, content: text, href: "0")]
        }

        let ns = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else {
            let text = HTMLTextExtractor.plainText(from: html)
            return text.isEmpty ? [] : [LocalChapter(title: fallbackTitle, content: text, href: "0")]
        }

        var chapters: [LocalChapter] = []

        // 第一个标题之前的内容
        let headLength = matches[0].range.location
        if headLength > 0 {
            let head = HTMLTextExtractor.plainText(from: ns.substring(with: NSRange(location: 0, length: headLength)))
            if !head.isEmpty {
                chapters.append(LocalChapter(title: fallbackTitle, content: head, href: "0"))
            }
        }

        for (index, match) in matches.enumerated() {
            let titleRaw = ns.substring(with: match.range(at: 2))
            var title = HTMLTextExtractor.plainText(from: titleRaw)
            if title.isEmpty { title = "第\(chapters.count + 1)章" }

            let bodyStart = match.range.location + match.range.length
            let bodyEnd = index + 1 < matches.count ? matches[index + 1].range.location : ns.length
            let bodyLength = max(0, bodyEnd - bodyStart)
            let bodyHTML = ns.substring(with: NSRange(location: bodyStart, length: bodyLength))
            let content = HTMLTextExtractor.plainText(from: bodyHTML)
            guard !content.isEmpty else { continue }

            chapters.append(LocalChapter(title: title, content: content, href: String(chapters.count)))
        }

        return chapters
    }

    /// Markdown 分章：按 # 标题切，正文去掉常见标记
    static func splitMarkdown(_ markdown: String, fallbackTitle: String) -> [LocalChapter] {
        let lines = markdown.components(separatedBy: "\n")
        var chapters: [LocalChapter] = []
        var currentTitle = fallbackTitle
        var buffer: [String] = []
        var inCodeBlock = false

        func flush() {
            let content = cleanMarkdown(buffer.joined(separator: "\n")).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { return }
            chapters.append(LocalChapter(title: currentTitle, content: content, href: String(chapters.count)))
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                inCodeBlock.toggle()
                continue
            }
            if !inCodeBlock, trimmed.hasPrefix("#") {
                let heading = trimmed.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                flush()
                buffer.removeAll()
                currentTitle = heading.isEmpty ? "第\(chapters.count + 1)章" : heading
                continue
            }
            buffer.append(line)
        }
        flush()

        if chapters.isEmpty {
            let content = cleanMarkdown(markdown).trimmingCharacters(in: .whitespacesAndNewlines)
            return content.isEmpty ? [] : [LocalChapter(title: fallbackTitle, content: content, href: "0")]
        }
        return chapters
    }

    private static func cleanMarkdown(_ text: String) -> String {
        var result = text
        // 图片、链接保留文字
        result = result.replacingOccurrences(of: "!\\[[^\\]]*\\]\\([^\\)]*\\)", with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "\\[([^\\]]*)\\]\\([^\\)]*\\)", with: "$1", options: .regularExpression)
        // 强调、行内代码、引用、列表符号
        result = result.replacingOccurrences(of: "(\\*\\*|__|\\*|_|`)", with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "(?m)^\\s{0,3}>\\s?", with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "(?m)^\\s{0,3}[-+*]\\s+", with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "(?m)^\\s{0,3}\\d+\\.\\s+", with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "(?m)^\\s{0,3}([-*_])\\s*\\1\\s*\\1[-\\s*_]*$", with: "", options: .regularExpression)
        return result
    }

    private static func splitByLength(_ text: String, chunkSize: Int) -> [String] {
        guard text.count > chunkSize else { return [text] }
        var chunks: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start, offsetBy: chunkSize, limitedBy: text.endIndex) ?? text.endIndex
            chunks.append(String(text[start..<end]))
            start = end
        }
        return chunks
    }
}
