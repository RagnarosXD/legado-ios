//
//  AnalyzeUrl.swift
//  Legado-iOS
//
//  URL 解析与构建器 - 参考原版 AnalyzeUrl.kt
//  支持 {{key}}、{{page}} 变量替换、POST body 解析、headers 解析
//

import Foundation
import WebKit

/// URL 解析结果
struct AnalyzedUrl {
    var url: String
    var method: HTTPMethod = .get
    var body: String?
    var headers: [String: String] = [:]
    var charset: String?
    var webView: Bool = false
    /// 以下字段对齐 Android AnalyzeUrl 的 `,{...}` 配置全集
    var retry: Int = 0
    var timeout: Int = 0
    var type: String?
    var dnsIp: String?
    var followRedirects: Bool = true
    var webJs: String?
    var serverID: String?
    var webViewDelayTime: Int = 0
    var origin: String?
    
    enum HTTPMethod: String {
        case get = "GET"
        case post = "POST"
    }
}

/// URL 构建器 - 将书源中的规则 URL 解析为实际可用的请求
class AnalyzeUrl {
    
    /// 解析搜索/发现 URL
    /// - Parameters:
    ///   - ruleUrl: 规则 URL，如 "https://example.com/search?q={{key}}&page={{page}},{"method":"POST"}"
    ///   - key: 搜索关键词
    ///   - page: 页码
    ///   - baseUrl: 书源 URL（用于解析相对路径）
    ///   - source: 书源（用于获取 headers 等配置）
    /// - Returns: 解析后的 URL 结构
    static func analyze(
        ruleUrl: String,
        key: String? = nil,
        page: Int = 1,
        baseUrl: String? = nil,
        source: BookSource? = nil
    ) -> AnalyzedUrl {
        var result = AnalyzedUrl(url: "")
        AppLogger.debug("AnalyzeUrl", "analyze 开始 len=\(ruleUrl.count) prefix=\(ruleUrl.prefix(80))")
        let templateContext = buildTemplateContext(key: key, page: page, source: source)

        // 0. Android analyzeJs：整条 URL 里的 <js> / @js: 段先执行，普通段用 @result 承接
        let jsResolvedRule = Self.analyzeJS(ruleUrl, source: source, baseUrl: baseUrl)

        // 0.1 页数规则：Android 支持 <1,2,3> 形式按页取地址
        let expandedRule = Self.expandPageRule(jsResolvedRule, page: page)

        // 1. 分离 URL 和配置 JSON
        var urlPart = expandedRule
        var configJson: [String: Any]?
        
        // 检查是否有 JSON 配置（以 , + { 分隔）
        if let jsonStart = findJsonConfig(in: expandedRule) {
            urlPart = String(expandedRule[..<jsonStart.lowerBound])
            let jsonStr = String(expandedRule[jsonStart.lowerBound...])
            if let data = jsonStr.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                configJson = json
            }
        }
        
        // 2. 变量替换
        let renderStart = Date()
        urlPart = replaceVariables(urlPart, context: templateContext)
        let renderCost = Int(Date().timeIntervalSince(renderStart) * 1000)
        if renderCost > 50 || urlPart.count > 2000 {
            AppLogger.debug("AnalyzeUrl", "变量替换完成 耗时=\(renderCost)ms outLen=\(urlPart.count)")
        }
        
        // 3. 解析 HTTP 方法
        if let method = configJson?["method"] as? String {
            result.method = method.uppercased() == "POST" ? .post : .get
        }
        
        // 4. 解析 POST body
        if let body = configJson?["body"] as? String {
            result.body = replaceVariables(body, context: templateContext)
        }
        
        // 5. 解析 headers
        if let headers = configJson?["headers"] as? [String: String] {
            result.headers = headers.mapValues { replaceVariables($0, context: templateContext) }
        }
        
        // 6. 解析编码
        if let charset = configJson?["charset"] as? String {
            result.charset = charset
        }
        
        // 7. 是否需要 WebView
        if let webView = configJson?["webView"] as? Bool {
            result.webView = webView
        }

        // 7.1 其余选项（对齐 AnalyzeUrl.kt:267-299）
        if let value = configJson?["retry"] as? NSNumber {
            result.retry = max(0, min(value.intValue, 3))
        }
        if let value = configJson?["timeout"] as? NSNumber {
            result.timeout = max(0, value.intValue)
        }
        result.type = configJson?["type"] as? String
        result.dnsIp = configJson?["dnsIp"] as? String ?? (configJson?["resolveIp"] as? String)
        if let value = configJson?["followRedirects"] as? Bool {
            result.followRedirects = value
        }
        result.webJs = configJson?["webJs"] as? String
        result.serverID = configJson?["serverID"] as? String
        result.origin = configJson?["origin"] as? String
        if let value = configJson?["webViewDelayTime"] as? NSNumber {
            result.webViewDelayTime = value.intValue
        }

        // js：用脚本改写最终 URL（Android: evalJS(js, url) 回填）
        if let js = configJson?["js"] as? String, !js.isEmpty {
            let rewritten = Self.evaluateJS(js, initialResult: urlPart, source: source, baseUrl: baseUrl)
            if !rewritten.isEmpty {
                urlPart = rewritten
            }
        }
        
        // 7.2 bodyJs：用脚本改写请求体
        if let bodyJs = configJson?["bodyJs"] as? String, !bodyJs.isEmpty, let body = result.body {
            let rewritten = Self.evaluateJS(bodyJs, initialResult: body, source: source, baseUrl: baseUrl)
            if !rewritten.isEmpty {
                result.body = rewritten
            }
        }

        // 8. 处理 URL 中的 POST 参数（用 , 分隔的旧格式）
        if result.method == .get && urlPart.contains(",{") == false {
            // 检查是否是 URL,body 的旧格式
            let parts = urlPart.split(separator: "\n", maxSplits: 1)
            if parts.count == 2 {
                urlPart = String(parts[0])
                result.body = replaceVariables(String(parts[1]), context: templateContext)
                result.method = .post
            }
        }
        
        // 8.5 Android：javascript: 开头的地址直接置空，避免发出畸形请求
        if urlPart.lowercased().hasPrefix("javascript") {
            AppLogger.debug("AnalyzeUrl", "javascript: 地址已置空")
            urlPart = ""
        }

        // 9. 处理相对 URL
        // 注意：不能用 hasPrefix("http") 判断绝对地址——协议相对地址（//host/path）和被误拼的
        // 绝对地址都会漏过去，之前就出现过 "https://站点/book-detail/https://另一站/..." 这种畸形 URL。
        if !hasScheme(urlPart) {
            if urlPart.hasPrefix("//") {
                // 协议相对：沿用 base 的 scheme
                if let base = baseUrl, let baseURL = URL(string: base), let scheme = baseURL.scheme {
                    urlPart = "\(scheme):\(urlPart)"
                }
            } else if let base = baseUrl, let baseURL = URL(string: base) {
                urlPart = URL(string: urlPart, relativeTo: baseURL)?.absoluteString ?? urlPart
            }
        }
        
        // 10. 合并书源 headers（对齐 Android BaseSource.getHeaderMap：
        //     header 字段可以是 <js>…</js> / @js:… 动态生成，解析失败只记日志不中断请求）
        if let source = source, let headerStr = source.header, !headerStr.isEmpty {
            let resolved = resolveHeaderRule(headerStr, source: source, baseUrl: urlPart)

            if let data = resolved.data(using: .utf8),
               let sourceHeaders = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
                for (key, value) in sourceHeaders where result.headers[key] == nil {
                    result.headers[key] = replaceVariables(value, context: templateContext)
                }
            } else {
                AppLogger.warn("AnalyzeUrl", "\(source.bookSourceName) header 解析失败，已忽略：\(resolved.prefix(120))")
            }
        }
        
        // 10.1 合并登录头（对齐 Android getHeaderMap(hasLoginHeader = true)）
        if let source {
            let loginHeaders = source.loginHeaderMap
            for (key, value) in loginHeaders where result.headers[key] == nil {
                result.headers[key] = value
            }
        }

        // 11. 添加默认 User-Agent
        if result.headers["User-Agent"] == nil {
            result.headers["User-Agent"] = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.5 Mobile/15E148 Safari/604.1"
        }
        
        result.url = urlPart
        return result
    }
    
    // MARK: - 书源 header 的动态 JS（Android BaseSource.getHeaderMap）

    /// 支持三种写法：
    /// 1. 整体是 JS：`<js>JSON.stringify({...})</js>` 或 `@js:...`
    /// 2. 值内嵌 JS：`{"X-Sign":"<js>java.md5(...)</js>"}`
    /// 3. 普通 JSON 字符串（原样返回）
    static func resolveHeaderRule(_ header: String, source: BookSource?, baseUrl: String?) -> String {
        let trimmed = header.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return header }

        let lowered = trimmed.lowercased()

        // 情况 1：整条 header 就是脚本
        if lowered.hasPrefix("<js>") || lowered.hasPrefix("@js:") {
            return analyzeJS(trimmed, source: source, baseUrl: baseUrl)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // 情况 3：不含 JS，直接返回
        guard lowered.contains("<js>") || lowered.contains("@js:") else { return trimmed }

        // 情况 2：逐值求值
        if let data = trimmed.data(using: .utf8),
           var parsed = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            for (key, value) in parsed {
                let valueLowered = value.lowercased()
                guard valueLowered.contains("<js>") || valueLowered.hasPrefix("@js:") else { continue }
                parsed[key] = analyzeJS(value, source: source, baseUrl: baseUrl)
            }

            if let encoded = try? JSONSerialization.data(withJSONObject: parsed),
               let text = String(data: encoded, encoding: .utf8) {
                return text
            }
            return trimmed
        }

        // 结构不是合法 JSON：整条当脚本执行
        return analyzeJS(trimmed, source: source, baseUrl: baseUrl)
    }

    // MARK: - URL 级 JS（Android analyzeJs）

    private static let jsEngine = RuleEngine()

    /// 对齐 Android AnalyzeUrl.analyzeJs：
    /// `<js>...</js>` / `@js:...` 段执行脚本，普通段把 `@result` 替换成当前值后拼接
    static func analyzeJS(_ ruleUrl: String, source: BookSource?, baseUrl: String?) -> String {
        let lowered = ruleUrl.lowercased()
        guard lowered.contains("<js>") || lowered.contains("@js:") else { return ruleUrl }

        let segments = RuleSplitter.splitByJSSegments(ruleUrl)
        guard segments.count > 1 else { return ruleUrl }

        var result = ""
        for segment in segments {
            if segment.isJS {
                result = evaluateJS(segment.text, initialResult: result, source: source, baseUrl: baseUrl)
            } else {
                var text = segment.text
                if !result.isEmpty {
                    text = text.replacingOccurrences(of: "@result", with: result)
                }
                result += text
            }
        }

        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? ruleUrl : trimmed
    }

    /// 执行一段 JS，`result` 变量由 initialResult 注入（Android evalJS 的 result 绑定）
    static func evaluateJS(
        _ script: String,
        initialResult: String,
        source: BookSource?,
        baseUrl: String?
    ) -> String {
        let context = ElementContext(element: "", baseUrl: baseUrl, source: source)
        context.initialResult = initialResult

        let value = (try? jsEngine.getString(
            ruleStr: "@js:" + script,
            elementContext: context,
            baseUrl: baseUrl
        )) ?? ""

        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 变量替换
    
    /// 替换 URL 中的变量占位符
    private static func replaceVariables(_ input: String, context: ExecutionContext) -> String {
        TemplateEngine.render(input, context: context)
    }

    private static func buildTemplateContext(key: String?, page: Int, source: BookSource?) -> ExecutionContext {
        let context = ExecutionContext()

        if let key {
            let encodedKey = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? key
            context.variables["key"] = encodedKey
            context.variables["searchKey"] = encodedKey
        }

        context.variables["page"] = "\(page)"
        context.variables["page-1"] = "\(page - 1)"

        if let variable = source?.variable,
           let data = variable.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for (name, value) in json {
                if let string = value as? String {
                    context.variables[name] = string
                } else if let bool = value as? Bool {
                    context.variables[name] = bool ? "true" : "false"
                } else if let number = value as? NSNumber {
                    context.variables[name] = number.stringValue
                }
            }
        }

        return context
    }
    
    /// 对齐 Android replaceKeyPageJs：`<1,2,3>` 按页码取地址，超出长度取最后一个
    static func expandPageRule(_ ruleUrl: String, page: Int) -> String {
        guard let start = ruleUrl.firstIndex(of: "<"),
              let end = ruleUrl[start...].firstIndex(of: ">") else {
            return ruleUrl
        }

        let inner = String(ruleUrl[ruleUrl.index(after: start)..<end])
        let parts = inner
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        // 必须是真的页数列表（≥2 段且都非空），避免误伤 URL 里的 "<"
        guard parts.count > 1, parts.allSatisfy({ !$0.isEmpty }) else { return ruleUrl }

        let index = min(max(page - 1, 0), parts.count - 1)
        var expanded = ruleUrl
        expanded.replaceSubrange(start...end, with: parts[index])
        AppLogger.debug("AnalyzeUrl", "页数规则 page=\(page) 取第 \(index + 1) 段")
        return expanded
    }

    /// 是否已经带协议（http://、https://、file:// 等）
    private static func hasScheme(_ value: String) -> Bool {
        guard let match = value.range(
            of: "^[a-zA-Z][a-zA-Z0-9+.\\-]*://",
            options: .regularExpression
        ) else { return false }
        return match.lowerBound == value.startIndex
    }

    // MARK: - JSON 配置查找
    
    /// 在 URL 字符串中查找 JSON 配置的起始位置
    private static func findJsonConfig(in url: String) -> Range<String.Index>? {
        // 查找 ,{ 模式，但要排除 URL 本身包含的 { }
        var braceDepth = 0
        var lastCommaIndex: String.Index?
        
        for i in url.indices {
            let char = url[i]
            if char == "{" {
                if braceDepth == 0 && lastCommaIndex != nil {
                    return lastCommaIndex!..<url.endIndex
                }
                braceDepth += 1
            } else if char == "}" {
                braceDepth -= 1
            } else if char == "," && braceDepth == 0 {
                lastCommaIndex = i
            }
        }
        
        return nil
    }
    
    // MARK: - 发起请求
    
    /// 使用解析后的 URL 发起网络请求并返回响应内容
    static func getResponseBody(
        analyzedUrl: AnalyzedUrl,
        charset: String.Encoding = .utf8
    ) async throws -> (body: String, url: String) {
        // 章节地址常带中文/空格/换行（书源规则直接拼出来的），URL(string:) 会返回 nil，
        // 表现为 NSURLErrorDomain -1000；这里先原样解析，失败再补百分号编码重试
        let url: URL
        if let direct = URL(string: analyzedUrl.url) {
            url = direct
        } else {
            let encoded = encodeIfNeeded(analyzedUrl.url)
            guard let retried = URL(string: encoded) else {
                AppLogger.error("HTTP", "URL 非法（已尝试编码重试）：\(analyzedUrl.url.prefix(220))")
                throw URLError(.badURL)
            }
            AppLogger.warn("HTTP", "URL 含未编码字符，已自动编码：\(encoded.prefix(220))")
            url = retried
        }

        // dnsIp：把域名直连到指定 IP（对齐 Android 的 Dns 替换）
        // https 因证书校验与 SNI 绑定无法在 URLSession 层实现，这里只对 http 生效
        var requestUrl = url
        var dnsHostHeader: String?

        if let dnsIp = analyzedUrl.dnsIp?.trimmingCharacters(in: .whitespaces), !dnsIp.isEmpty {
            if url.scheme?.lowercased() == "http" {
                let ip = dnsIp.split(separator: ",").first
                    .map { String($0).trimmingCharacters(in: .whitespaces) } ?? dnsIp

                if let replaced = replaceHost(url, with: ip) {
                    requestUrl = replaced
                    dnsHostHeader = url.host
                    AppLogger.debug("HTTP", "dnsIp 直连 \(url.host ?? "") → \(ip)")
                }
            } else {
                AppLogger.warn("HTTP", "dnsIp 仅对 http 生效（https 需证书与 SNI 匹配）：\(url.absoluteString.prefix(100))")
            }
        }

        var request = URLRequest(url: requestUrl)
        request.httpMethod = analyzedUrl.method.rawValue
        // 多书源搜索时要快速失败；书源配置了 timeout（毫秒）则优先使用
        if analyzedUrl.timeout > 0 {
            request.timeoutInterval = TimeInterval(analyzedUrl.timeout) / 1000
        } else {
            request.timeoutInterval = 12
        }
        
        // 设置 headers
        for (key, value) in analyzedUrl.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        // dnsIp 直连时保留原始域名（HTTP/1.1 靠 Host 头区分虚拟主机）
        if let dnsHostHeader, request.value(forHTTPHeaderField: "Host") == nil {
            request.setValue(dnsHostHeader, forHTTPHeaderField: "Host")
        }
        
        // 设置 body
        if let body = analyzedUrl.body {
            let hasContentType = request.value(forHTTPHeaderField: "Content-Type") != nil
            let looksLikeJSON = body.hasPrefix("{") || body.hasPrefix("[")
            let looksLikeXML = body.hasPrefix("<")

            if !hasContentType, !looksLikeJSON, !looksLikeXML, analyzedUrl.method == .post {
                // Android analyzeFields：表单体逐字段编码（空格→+，中文百分号编码）
                request.httpBody = encodeFormBody(body, charsetName: analyzedUrl.charset)
                request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            } else {
                request.httpBody = body.data(using: .utf8)
            }
        }

        if analyzedUrl.webView {
            let fetcher = await WebViewHTMLFetcher()
            let result = try await fetcher.fetchHTML(request: request, timeout: request.timeoutInterval)
            return (result.html, result.finalURL)
        }
        
        let startedAt = Date()
        AppLogger.debug("HTTP", "\(request.httpMethod ?? "GET") \(url.absoluteString.prefix(200))")

        // 重试：对齐 Android urlOption.retry（0~3）
        var attempt = 0
        var data = Data()
        var rawResponse: URLResponse?
        var lastError: Error?

        while attempt <= analyzedUrl.retry {
            do {
                // followRedirects=false：用不跟随重定向的 session，直接拿 3xx 响应体
                let session = analyzedUrl.followRedirects
                    ? URLSession.shared
                    : NoRedirectSession.shared.session
                let (payload, resp) = try await session.data(for: request)
                data = payload
                rawResponse = resp
                lastError = nil
                break
            } catch {
                lastError = error
                attempt += 1
                if attempt <= analyzedUrl.retry {
                    AppLogger.warn("HTTP", "重试 \(attempt)/\(analyzedUrl.retry) url=\(url.absoluteString.prefix(120))")
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }
            }
        }

        if let lastError { throw lastError }
        guard let response = rawResponse else { throw URLError(.unknown) }

        // 处理编码
        let encoding = detectEncoding(data: data, response: response, charset: analyzedUrl.charset)

        // type：直接按字节输出（对齐 Android AnalyzeUrl 的 type 字段，如 hex / base64）
        if let type = analyzedUrl.type?.trimmingCharacters(in: .whitespaces).lowercased(),
           !type.isEmpty, type != "text" {
            let text: String
            switch type {
            case "hex":
                text = data.map { String(format: "%02x", $0) }.joined()
            case "base64":
                text = data.base64EncodedString()
            default:
                text = String(data: data, encoding: encoding) ?? ""
            }

            let typedUrl = (response as? HTTPURLResponse)?.url?.absoluteString ?? analyzedUrl.url
            AppLogger.info("HTTP", "type=\(type) bytes=\(data.count) chars=\(text.count)")
            return (text, typedUrl)
        }

        let body = String(data: data, encoding: encoding) ?? String(data: data, encoding: .utf8) ?? ""

        let finalUrl = (response as? HTTPURLResponse)?.url?.absoluteString ?? analyzedUrl.url
        let cost = Int(Date().timeIntervalSince(startedAt) * 1000)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        AppLogger.info("HTTP", "status=\(status) bytes=\(data.count) chars=\(body.count) 耗时=\(cost)ms")

        return (body, finalUrl)
    }
    
    /// 替换 URL 的 host（dnsIp 直连用）
    private static func replaceHost(_ url: URL, with ip: String) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.host = ip
        return components.url
    }

    /// 表单体逐字段编码（对齐 Android encodeParams：`&` 分段、`=` 分键值、空格→`+`）
    static func encodeFormBody(_ body: String, charsetName: String?) -> Data? {
        let pairs = body.split(separator: "&", omittingEmptySubsequences: false)
        var encoded: [String] = []

        for pair in pairs {
            let text = String(pair)
            let parts = text.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = parts.first.map(String.init) ?? ""
            let value = parts.count > 1 ? String(parts[1]) : ""

            if value.isEmpty {
                encoded.append(percentEncodeForm(key))
            } else {
                encoded.append(percentEncodeForm(key) + "=" + percentEncodeForm(value))
            }
        }

        return encoded.joined(separator: "&").data(using: .utf8)
    }

    /// RFC3986 严格编码，空格按 form 规则转成 `+`
    private static func percentEncodeForm(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "*-._")
        let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
        return encoded.replacingOccurrences(of: "%20", with: "+")
    }

    /// 补全 URL 中未编码的字符（中文、空格、换行等），已编码的 %XX 保持不变
    static func encodeIfNeeded(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var allowed = CharacterSet.urlQueryAllowed
        // URL 结构字符与已编码标记必须保留，否则会把 %E4 变成 %25E4
        allowed.insert(charactersIn: "#[]@!$&'()*+,;=:/?%")
        return trimmed.addingPercentEncoding(withAllowedCharacters: allowed) ?? trimmed
    }

    // MARK: - 编码检测
    
    /// 自动检测响应内容的编码
    private static func detectEncoding(data: Data, response: URLResponse, charset: String?) -> String.Encoding {
        // 1. 优先使用书源指定的编码
        if let charset = charset {
            switch charset.lowercased() {
            case "gbk", "gb2312", "gb18030":
                return String.Encoding(
                    rawValue: CFStringConvertEncodingToNSStringEncoding(
                        CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
                    )
                )
            case "big5":
                return String.Encoding(
                    rawValue: CFStringConvertEncodingToNSStringEncoding(
                        CFStringEncoding(CFStringEncodings.big5.rawValue)
                    )
                )
            default:
                break
            }
        }
        
        // 2. 从 HTTP 响应头检测
        if let httpResponse = response as? HTTPURLResponse,
           let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") {
            if contentType.lowercased().contains("gbk") || contentType.lowercased().contains("gb2312") {
                return String.Encoding(
                    rawValue: CFStringConvertEncodingToNSStringEncoding(
                        CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
                    )
                )
            }
        }
        
        // 3. 从 HTML meta 标签检测
        if data.count > 0 {
            let prefix = String(data: data.prefix(1024), encoding: .ascii) ?? ""
            if prefix.lowercased().contains("charset=gbk") ||
               prefix.lowercased().contains("charset=gb2312") {
                return String.Encoding(
                    rawValue: CFStringConvertEncodingToNSStringEncoding(
                        CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
                    )
                )
            }
        }
        
        // 4. 默认 UTF-8
        return .utf8
    }
}

@MainActor
private final class WebViewHTMLFetcher: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<(html: String, finalURL: String), Error>?
    private var webView: WKWebView?
    private var timeoutTask: Task<Void, Never>?
    private var requestedURL: URL?

    func fetchHTML(request: URLRequest, timeout: TimeInterval) async throws -> (html: String, finalURL: String) {
        if continuation != nil {
            throw WebViewFetchError.invalidState
        }

        requestedURL = request.url

        return try await withCheckedThrowingContinuation { cont in
            continuation = cont

            let config = WKWebViewConfiguration()
            config.websiteDataStore = .default()

            let webView = WKWebView(frame: .zero, configuration: config)
            self.webView = webView
            webView.navigationDelegate = self
            webView.load(request)

            timeoutTask = Task { [weak self] in
                let nanos = UInt64(max(1.0, timeout) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
                await MainActor.run {
                    self?.finish(.failure(WebViewFetchError.timeout))
                }
            }
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 150_000_000)
            } catch {
            }

            webView.evaluateJavaScript("document.documentElement.outerHTML") { [weak self] result, error in
                guard let self else { return }
                Task { @MainActor in
                    if let error {
                        self.finish(.failure(error))
                        return
                    }
                    guard let html = result as? String, !html.isEmpty else {
                        self.finish(.failure(WebViewFetchError.noHTML))
                        return
                    }
                    let finalURL = webView.url?.absoluteString ?? self.requestedURL?.absoluteString ?? ""
                    self.finish(.success((html: html, finalURL: finalURL)))
                }
            }
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            finish(.failure(error))
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            finish(.failure(error))
        }
    }

    private func finish(_ result: Result<(html: String, finalURL: String), Error>) {
        guard let continuation else { return }
        self.continuation = nil

        timeoutTask?.cancel()
        timeoutTask = nil

        webView?.navigationDelegate = nil
        webView = nil
        requestedURL = nil

        switch result {
        case .success(let value):
            continuation.resume(returning: value)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}

private enum WebViewFetchError: LocalizedError {
    case timeout
    case noHTML
    case invalidState

    var errorDescription: String? {
        switch self {
        case .timeout:
            return "WebView 加载超时"
        case .noHTML:
            return "WebView 未返回 HTML"
        case .invalidState:
            return "WebView 请求状态异常"
        }
    }
}

// MARK: - 不跟随重定向（对齐 Android OkHttp followRedirects(false)）

final class NoRedirectSession {

    static let shared = NoRedirectSession()

    let session: URLSession

    private init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 30
        session = URLSession(
            configuration: configuration,
            delegate: NoRedirectDelegate(),
            delegateQueue: nil
        )
    }
}

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {

    /// 返回 nil 表示不跟随重定向，回调会拿到原始 3xx 响应
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
