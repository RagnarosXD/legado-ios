//
//  WebBook.swift
//  Legado-iOS
//
//  网络书籍操作核心模块 - 参考原版 WebBook.kt
//  提供搜索、获取书籍信息、获取目录、获取正文的完整链路
//

import Foundation
import CoreData
import SwiftSoup

/// 搜索结果
struct SearchBookResult {
    var name: String = ""
    var author: String = ""
    var bookUrl: String = ""
    var coverUrl: String?
    var intro: String?
    var lastChapter: String?
    var wordCount: String?
    var sourceUrl: String = ""       // 来源书源 URL
    var sourceName: String = ""      // 来源书源名称
}

/// 章节信息（用于远程获取）
struct WebChapter {
    var title: String = ""
    var url: String = ""
    var index: Int = 0
    var isVip: Bool = false
}

/// WebBook 核心操作类
/// 整个类固定在主线程执行：入参是 Core Data 的 BookSource/Book，规则解析还会创建 JavaScriptCore 上下文，
/// 两者都不允许在后台线程触碰（这是 1.2.0 并发搜索、批量校验闪退的根因）。
/// 网络请求本身是 async，await 期间主线程会释放，所以并发仍然有效。
@MainActor
class WebBook {
    
    private static let ruleEngine = RuleEngine()
    
    // MARK: - 搜索
    
    /// 在指定书源中搜索书籍
    static func searchBook(
        source: BookSource,
        key: String,
        page: Int = 1
    ) async throws -> [SearchBookResult] {
        guard let searchUrl = source.searchUrl, !searchUrl.isEmpty else {
            throw WebBookError.noSearchUrl
        }

        let prepareStart = Date()
        AppLogger.info("WebBook", "准备搜索 \(source.bookSourceName) searchUrl=\(searchUrl.prefix(180))")

        // 有些书源的 searchUrl 整条就是规则（@js: / <js> / {{...}}），要先算出真实 URL
        var resolvedUrl = searchUrl
        let trimmedUrl = searchUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedUrl.hasPrefix("@js:") || trimmedUrl.hasPrefix("<js") || trimmedUrl.hasPrefix("{{") {
            // 多行 JS 脚本在搜索 URL 里执行会阻塞主线程（严重时被 watchdog 杀掉），超长直接跳过
            let scriptLimit = 4000
            guard trimmedUrl.count <= scriptLimit else {
                AppLogger.warn("WebBook", "searchUrl 规则过长跳过 \(source.bookSourceName) len=\(trimmedUrl.count)")
                throw WebBookError.noSearchUrl
            }

            // 生成 URL 的脚本里如果还在同步抓网络（java.ajax），很容易把主线程卡死，直接跳过
            if trimmedUrl.contains("java.ajax") {
                AppLogger.warn("WebBook", "searchUrl 规则含 java.ajax，跳过以避免主线程阻塞 \(source.bookSourceName)")
                throw WebBookError.noSearchUrl
            }

            let context = ElementContext(element: "", baseUrl: source.bookSourceUrl, source: source)
            context.variables["key"] = key
            context.variables["page"] = String(page)

            let startedAt = Date()
            let evaluated = (try? ruleEngine.getString(
                ruleStr: trimmedUrl,
                elementContext: context,
                baseUrl: source.bookSourceUrl
            )) ?? ""
            let cost = Int(Date().timeIntervalSince(startedAt) * 1000)
            AppLogger.info("WebBook", "searchUrl 规则执行 \(source.bookSourceName) 耗时=\(cost)ms")

            let candidate = evaluated.trimmingCharacters(in: .whitespacesAndNewlines)
            guard candidate.hasPrefix("http") else {
                // 绝不把 JS 源码当成 URL 去拼接：之前就是这条路径导致崩溃
                AppLogger.warn("WebBook", "searchUrl 规则未生成合法地址，跳过 \(source.bookSourceName) 结果=\(candidate.prefix(120))")
                throw WebBookError.noSearchUrl
            }

            resolvedUrl = candidate
            AppLogger.info("WebBook", "搜索URL 由规则生成：\(candidate.prefix(180))")
        }

        // 1. 构建搜索 URL
        let analyzedUrl = AnalyzeUrl.analyze(
            ruleUrl: resolvedUrl,
            key: key,
            page: page,
            baseUrl: source.bookSourceUrl,
            source: source
        )
        
        let prepareCost = Int(Date().timeIntervalSince(prepareStart) * 1000)
        AppLogger.info("WebBook", "搜索URL \(analyzedUrl.url.prefix(220)) 构建耗时=\(prepareCost)ms")

        // 2. 发起请求
        let (body, redirectUrl) = try await AnalyzeUrl.getResponseBody(analyzedUrl: analyzedUrl)

        guard !body.isEmpty else {
            AppLogger.warn("WebBook", "搜索响应为空 \(source.bookSourceName)")
            throw WebBookError.emptyResponse
        }

        // 安全阀：超大响应在解析阶段可能卡死主线程（正则回溯/SwiftSoup 构建），直接跳过
        let maxBodySize = 512 * 1024
        guard body.count <= maxBodySize else {
            AppLogger.warn("WebBook", "响应过大跳过解析 \(source.bookSourceName) chars=\(body.count)")
            throw WebBookError.parseFailed("响应过大（\(body.count) 字符）")
        }

        // 3. 解析搜索结果
        guard let searchRule = source.getSearchRule() else {
            AppLogger.error("WebBook", "缺少搜索规则 \(source.bookSourceName)")
            throw WebBookError.noRule("搜索规则")
        }

        let parsed = try parseBookList(
            source: source,
            body: body,
            baseUrl: redirectUrl,
            bookListRule: searchRule.bookList,
            nameRule: searchRule.name,
            authorRule: searchRule.author,
            bookUrlRule: searchRule.bookUrl,
            coverUrlRule: searchRule.coverUrl,
            introRule: searchRule.intro,
            lastChapterRule: searchRule.lastChapter,
            wordCountRule: searchRule.wordCount
        )

        AppLogger.info("WebBook", "搜索解析 \(source.bookSourceName) 结果=\(parsed.count)")
        return parsed
    }
    
    // MARK: - 获取书籍详情
    
    /// 获取书籍详细信息
    static func getBookInfo(
        source: BookSource,
        book: Book
    ) async throws {
        guard let infoRule = source.getBookInfoRule() else {
            throw WebBookError.noRule("书籍信息规则")
        }
        
        // 1. 请求详情页
        let analyzedUrl = AnalyzeUrl.analyze(
            ruleUrl: sanitizeURL(book.bookUrl),
            baseUrl: source.bookSourceUrl,
            source: source
        )
        let (body, redirectUrl) = try await AnalyzeUrl.getResponseBody(analyzedUrl: analyzedUrl)
        
        guard !body.isEmpty else {
            throw WebBookError.emptyResponse
        }
        
        // 2. 解析书籍信息
        let isJson = body.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") ||
                     body.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("[")
        
        let context = ExecutionContext()
        if isJson {
            context.jsonString = body
        } else {
            context.document = try SwiftSoup.parse(body)
        }
        context.baseURL = URL(string: redirectUrl)
        
        let elementCtx = ElementContext(
            element: isJson ? (try JSONSerialization.jsonObject(with: body.data(using: .utf8) ?? Data()) as Any) :
                     (try SwiftSoup.parse(body) as Any),
            baseUrl: redirectUrl,
            source: source
        )

        // 2.5 init 规则：一般只做 @put，把后续字段要用的变量先算出来
        if let initRule = infoRule.initRule, !initRule.isEmpty {
            _ = ruleEngine.getString(ruleStr: initRule, elementContext: elementCtx, baseUrl: redirectUrl)
        }

        // 3. 填充书籍信息
        if let name = infoRule.name {
            let parsed = ruleEngine.getString(ruleStr: name, elementContext: elementCtx, baseUrl: redirectUrl)
            if !parsed.isEmpty { book.name = parsed }
        }
        if let author = infoRule.author {
            let parsed = ruleEngine.getString(ruleStr: author, elementContext: elementCtx, baseUrl: redirectUrl)
            if !parsed.isEmpty { book.author = parsed }
        }
        if let intro = infoRule.intro {
            let parsed = ruleEngine.getString(ruleStr: intro, elementContext: elementCtx, baseUrl: redirectUrl)
            if !parsed.isEmpty { book.intro = parsed }
        }
        if let coverUrl = infoRule.coverUrl {
            let parsed = ruleEngine.getString(ruleStr: coverUrl, elementContext: elementCtx, baseUrl: redirectUrl)
            if !parsed.isEmpty { book.coverUrl = parsed }
        }
        if let tocUrl = infoRule.tocUrl {
            let parsed = ruleEngine.getString(ruleStr: tocUrl, elementContext: elementCtx, baseUrl: redirectUrl)
            if !parsed.isEmpty { book.tocUrl = parsed }
        }
        if let lastChapter = infoRule.lastChapter {
            let parsed = ruleEngine.getString(ruleStr: lastChapter, elementContext: elementCtx, baseUrl: redirectUrl)
            if !parsed.isEmpty { book.latestChapterTitle = parsed }
        }
    }
    
    // MARK: - 获取目录
    
    /// 获取书籍章节目录
    static func getChapterList(
        source: BookSource,
        book: Book
    ) async throws -> [WebChapter] {
        guard let tocRule = source.getTocRule() else {
            throw WebBookError.noRule("目录规则")
        }
        
        let tocUrl = book.tocUrl.isEmpty ? book.bookUrl : book.tocUrl
        
        // 1. 请求目录页
        let analyzedUrl = AnalyzeUrl.analyze(
            ruleUrl: sanitizeURL(tocUrl),
            baseUrl: source.bookSourceUrl,
            source: source
        )
        let (body, redirectUrl) = try await AnalyzeUrl.getResponseBody(analyzedUrl: analyzedUrl)
        
        guard !body.isEmpty else {
            throw WebBookError.emptyResponse
        }
        
        // 2. 解析章节列表
        var chapters: [WebChapter] = []
        
        let elements = try ruleEngine.getElements(
            ruleStr: tocRule.chapterList,
            body: body,
            baseUrl: redirectUrl
        )
        
        for (index, elementCtx) in elements.enumerated() {
            elementCtx.source = source
            var chapter = WebChapter()
            chapter.index = index
            
            chapter.title = ruleEngine.getString(
                ruleStr: tocRule.chapterName,
                elementContext: elementCtx,
                baseUrl: redirectUrl
            )
            
            chapter.url = ruleEngine.getString(
                ruleStr: tocRule.chapterUrl,
                elementContext: elementCtx,
                baseUrl: redirectUrl
            )
            
            if let isVipRule = tocRule.isVip {
                let vipStr = ruleEngine.getString(ruleStr: isVipRule, elementContext: elementCtx)
                chapter.isVip = vipStr == "true" || vipStr == "1"
            }
            
            if !chapter.title.isEmpty {
                chapters.append(chapter)
            }
        }
        
        // 3. 处理目录分页（nextTocUrl）
        if let nextTocUrlRule = tocRule.nextTocUrl, !nextTocUrlRule.isEmpty {
            var nextBody = body
            var nextRedirectUrl = redirectUrl
            
            while true {
                let context = ExecutionContext()
                context.document = try SwiftSoup.parse(nextBody)
                context.baseURL = URL(string: nextRedirectUrl)
                
                let elementCtx = ElementContext(
                    element: try SwiftSoup.parse(nextBody),
                    baseUrl: nextRedirectUrl
                )
                let nextUrl = ruleEngine.getString(ruleStr: nextTocUrlRule, elementContext: elementCtx, baseUrl: nextRedirectUrl)
                
                guard !nextUrl.isEmpty, nextUrl != nextRedirectUrl else { break }
                
                let nextAnalyzedUrl = AnalyzeUrl.analyze(
                    ruleUrl: nextUrl,
                    baseUrl: source.bookSourceUrl,
                    source: source
                )
                let result = try await AnalyzeUrl.getResponseBody(analyzedUrl: nextAnalyzedUrl)
                nextBody = result.body
                nextRedirectUrl = result.url
                
                let nextElements = try ruleEngine.getElements(
                    ruleStr: tocRule.chapterList,
                    body: nextBody,
                    baseUrl: nextRedirectUrl
                )
                
                for elementCtx in nextElements {
                    elementCtx.source = source
                    var chapter = WebChapter()
                    chapter.index = chapters.count
                    chapter.title = ruleEngine.getString(ruleStr: tocRule.chapterName, elementContext: elementCtx, baseUrl: nextRedirectUrl)
                    chapter.url = ruleEngine.getString(ruleStr: tocRule.chapterUrl, elementContext: elementCtx, baseUrl: nextRedirectUrl)
                    
                    if !chapter.title.isEmpty {
                        chapters.append(chapter)
                    }
                }
                
                // 防止无限循环，最多 100 页
                if chapters.count > 10000 { break }
            }
        }
        
        return chapters
    }
    
    // MARK: - 获取正文
    
    /// 获取章节正文内容
    static func getContent(
        source: BookSource,
        book: Book,
        chapter: BookChapter
    ) async throws -> String {
        guard let contentRule = source.getContentRule() else {
            throw WebBookError.noRule("正文规则")
        }
        
        guard let ruleStr = contentRule.content, !ruleStr.isEmpty else {
            throw WebBookError.noRule("正文规则")
        }
        
        // 1. 请求正文页
        let analyzedUrl = AnalyzeUrl.analyze(
            ruleUrl: sanitizeURL(chapter.chapterUrl),
            baseUrl: source.bookSourceUrl,
            source: source
        )
        let (body, redirectUrl) = try await AnalyzeUrl.getResponseBody(analyzedUrl: analyzedUrl)
        
        guard !body.isEmpty else {
            throw WebBookError.emptyResponse
        }
        
        // 2. 解析正文
        let context = ExecutionContext()
        let isJson = body.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{")
        
        if isJson {
            context.jsonString = body
        } else {
            context.document = try SwiftSoup.parse(body)
        }
        context.baseURL = URL(string: redirectUrl)
        
        let elementCtx = ElementContext(
            element: isJson ? (try JSONSerialization.jsonObject(with: body.data(using: .utf8) ?? Data()) as Any) :
                     (try SwiftSoup.parse(body) as Any),
            baseUrl: redirectUrl,
            source: source
        )

        // joinAll：正文规则常常命中多个段落节点，需要全部拼接
        var content = ruleEngine.getString(ruleStr: ruleStr,
                                           elementContext: elementCtx,
                                           baseUrl: redirectUrl,
                                           joinAll: true)
        
        // 3. 处理正文分页（nextContentUrl）
        if let nextContentUrlRule = contentRule.nextContentUrl, !nextContentUrlRule.isEmpty {
            var nextBody = body
            var nextRedirectUrl = redirectUrl
            
            for _ in 0..<50 {  // 最多 50 页
                let nextElementCtx = ElementContext(
                    element: try SwiftSoup.parse(nextBody),
                    baseUrl: nextRedirectUrl
                )
                let nextUrl = ruleEngine.getString(ruleStr: nextContentUrlRule, elementContext: nextElementCtx, baseUrl: nextRedirectUrl)
                
                guard !nextUrl.isEmpty, nextUrl != nextRedirectUrl else { break }
                
                let nextAnalyzedUrl = AnalyzeUrl.analyze(
                    ruleUrl: nextUrl,
                    baseUrl: source.bookSourceUrl,
                    source: source
                )
                let result = try await AnalyzeUrl.getResponseBody(analyzedUrl: nextAnalyzedUrl)
                nextBody = result.body
                nextRedirectUrl = result.url
                
                let nextElementCtxInner = ElementContext(
                    element: try SwiftSoup.parse(nextBody),
                    baseUrl: nextRedirectUrl,
                    source: source
                )
                let nextContent = ruleEngine.getString(ruleStr: ruleStr,
                                                       elementContext: nextElementCtxInner,
                                                       baseUrl: nextRedirectUrl,
                                                       joinAll: true)
                
                if !nextContent.isEmpty {
                    content += "\n" + nextContent
                }
            }
        }
        
        // 4. 应用替换规则（净化）
        if let replaceRegex = contentRule.replaceRegex, !replaceRegex.isEmpty {
            content = applyReplaceRegex(content, regex: replaceRegex)
        }
        
        return content
    }
    
    /// 清洗解析结果里的 URL：去掉规则残留的 `##替换` 片段，避免把 `##` 编码进请求地址
    static func sanitizeURL(_ url: String) -> String {
        var value = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = value.range(of: "##") {
            value = String(value[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value
    }

    /// 相对地址补全（封面、详情页地址）
    static func normalizeURL(_ value: String, base: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") || trimmed.hasPrefix("data:") {
            return trimmed
        }
        guard let baseURL = URL(string: base) else { return trimmed }
        return URL(string: trimmed, relativeTo: baseURL)?.absoluteString ?? trimmed
    }

    // MARK: - 解析书籍列表
    
    /// 从 HTML/JSON 中解析书籍列表（搜索结果/发现列表通用）
    private static func parseBookList(
        source: BookSource,
        body: String,
        baseUrl: String,
        bookListRule: String?,
        nameRule: String?,
        authorRule: String?,
        bookUrlRule: String?,
        coverUrlRule: String?,
        introRule: String?,
        lastChapterRule: String?,
        wordCountRule: String?
    ) throws -> [SearchBookResult] {
        AppLogger.debug("Rule", "\(source.bookSourceName) bookList=\(bookListRule?.prefix(160) ?? "nil") bodyLen=\(body.count)")

        let elements = try ruleEngine.getElements(
            ruleStr: bookListRule,
            body: body,
            baseUrl: baseUrl
        )

        AppLogger.debug("Rule", "\(source.bookSourceName) 列表元素=\(elements.count)")

        var books: [SearchBookResult] = []

        for elementCtx in elements {
            elementCtx.source = source
            var book = SearchBookResult()
            book.sourceUrl = source.bookSourceUrl
            book.sourceName = source.bookSourceName

            // 单个字段解析失败不再让整源失败：返回空串并记录是哪条规则
            func value(_ rule: String?, _ label: String) -> String {
                guard let rule, !rule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
                do {
                    let text = try ruleEngine.getString(ruleStr: rule, elementContext: elementCtx, baseUrl: baseUrl)
                    if text.isEmpty {
                        AppLogger.debug("Rule", "\(source.bookSourceName) 字段 \(label) 为空 rule=\(rule.prefix(140))")
                        return ""
                    }
                    // 封面/详情地址兜底绝对化：部分规则走 JSON/XPath 分支时不会自动补全
                    if label == "coverUrl" || label == "bookUrl" {
                        return WebBook.normalizeURL(text, base: baseUrl)
                    }
                    return text
                } catch {
                    AppLogger.error("Rule", "\(source.bookSourceName) 字段 \(label) 失败 rule=\(rule.prefix(140)) err=\(error)")
                    return ""
                }
            }

            book.name = value(nameRule, "name")
            book.author = value(authorRule, "author")
            book.bookUrl = value(bookUrlRule, "bookUrl")
            book.coverUrl = value(coverUrlRule, "coverUrl")
            book.intro = value(introRule, "intro")
            book.lastChapter = value(lastChapterRule, "lastChapter")
            book.wordCount = value(wordCountRule, "wordCount")

            // 过滤无效结果
            if !book.name.isEmpty && !book.bookUrl.isEmpty {
                books.append(book)
            }
        }

        return books
    }
    
    // MARK: - 替换正则
    
    private static func applyReplaceRegex(_ content: String, regex: String) -> String {
        var result = content
        
        // 支持 "pattern##replacement" 格式
        let parts = regex.components(separatedBy: "##")
        if parts.count >= 2 {
            let pattern = parts[0]
            let replacement = parts[1]
            if let reg = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(result.startIndex..., in: result)
                result = reg.stringByReplacingMatches(in: result, range: range, withTemplate: replacement)
            }
        } else if let reg = try? NSRegularExpression(pattern: regex) {
            let range = NSRange(result.startIndex..., in: result)
            result = reg.stringByReplacingMatches(in: result, range: range, withTemplate: "")
        }
        
        return result
    }
}

// MARK: - 错误类型
enum WebBookError: LocalizedError {
    case noSearchUrl
    case noRule(String)
    case emptyResponse
    case parseFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .noSearchUrl: return "书源未配置搜索 URL"
        case .noRule(let name): return "书源未配置\(name)"
        case .emptyResponse: return "服务器响应为空"
        case .parseFailed(let msg): return "解析失败：\(msg)"
        }
    }
}
