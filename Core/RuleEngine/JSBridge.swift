import Foundation
import JavaScriptCore
import CryptoKit

class JSBridge {
    weak var context: ExecutionContext?
    weak var ruleEngine: RuleEngine?

    func inject(into jsContext: JSContext) {
        injectJavaObject(into: jsContext)
        injectSourceObject(into: jsContext)
        injectCookieObject(into: jsContext)
    }

    private func injectJavaObject(into jsContext: JSContext) {
        let javaObject = JSValue(newObjectIn: jsContext)

        let ajaxBlock: @convention(block) (String) -> String = { url in
            guard !url.isEmpty else { return "" }

            let headers = self.parseSourceHeaders()
            return JSBridgeHTTPClient.syncGet(url: url, headers: headers) ?? ""
        }

        let getStringAsyncBlock: @convention(block) (String) -> Void = { url in
            guard !url.isEmpty else { return }

            let headers = self.parseSourceHeaders()
            JSBridgeHTTPClient.asyncGet(url: url, headers: headers) { result in
                DispatchQueue.main.async {
                    self.context?.variables["result"] = result ?? ""
                }
            }
        }

        let putBlock: @convention(block) (String, String) -> Void = { key, value in
            self.context?.variables[key] = value
        }

        let getBlock: @convention(block) (String) -> String = { key in
            return self.context?.variables[key] ?? ""
        }

        let logBlock: @convention(block) (String) -> Void = { message in
            print("[JSBridge] \(message)")
        }

        // java.post(url, body, headersJson)
        let postBlock: @convention(block) (String, String, String) -> String = { url, body, headers in
            guard !url.isEmpty else { return "" }
            let merged = self.parseHeaders(headers) ?? self.parseSourceHeaders()
            return JSBridgeHTTPClient.syncPost(url: url, body: body, headers: merged) ?? ""
        }

        // java.ajaxAll(urls) —— 串行同步抓取，返回 JSON 数组字符串（由 JS 包装层转成真数组）
        let ajaxAllBlock: @convention(block) (String) -> String = { urlsJSON in
            guard let data = urlsJSON.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let urls = object as? [String] else {
                return "[]"
            }
            let headers = self.parseSourceHeaders()
            let results = urls.map { JSBridgeHTTPClient.syncGet(url: $0, headers: headers) ?? "" }
            guard let output = try? JSONSerialization.data(withJSONObject: results),
                  let json = String(data: output, encoding: .utf8) else {
                return "[]"
            }
            return json
        }

        // java.getString(rule) / java.getElements(rule)：在“当前页面上下文”上求值
        let ruleStringBlock: @convention(block) (String) -> String = { rule in
            guard let context = self.context, !rule.isEmpty else { return "" }
            let engine = RuleEngine()
            guard let result = try? engine.executeSingle(rule: rule, context: context) else { return "" }
            return result.text
        }

        let ruleElementsBlock: @convention(block) (String) -> String = { rule in
            guard let context = self.context, !rule.isEmpty else { return "[]" }
            let engine = RuleEngine()
            guard let result = try? engine.executeSingle(rule: rule, context: context) else { return "[]" }
            let values = result.list ?? (result.text.isEmpty ? [] : [result.text])
            guard let output = try? JSONSerialization.data(withJSONObject: values),
                  let json = String(data: output, encoding: .utf8) else {
                return "[]"
            }
            return json
        }

        let base64EncodeBlock: @convention(block) (String) -> String = { text in
            return Data(text.utf8).base64EncodedString()
        }

        let base64DecodeBlock: @convention(block) (String) -> String = { text in
            guard let data = Data(base64Encoded: text, options: .ignoreUnknownCharacters) else { return "" }
            return String(data: data, encoding: .utf8) ?? ""
        }

        let md5Block: @convention(block) (String) -> String = { text in
            let digest = Insecure.MD5.hash(data: Data(text.utf8))
            return digest.map { String(format: "%02x", $0) }.joined()
        }

        let md5ShortBlock: @convention(block) (String) -> String = { text in
            let digest = Insecure.MD5.hash(data: Data(text.utf8))
            return String(digest.map { String(format: "%02x", $0) }.joined().prefix(16))
        }

        // java.encodeURI(str, enc) / java.encodeURI(str)
        let encodeURIBlock: @convention(block) (String, String) -> String = { text, charset in
            let allowed = CharacterSet(charactersIn:
                "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")
            if charset.lowercased().contains("gb") {
                let cf = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
                if let data = text.data(using: String.Encoding(rawValue: cf)) {
                    return data.map { String(format: "%%%02X", $0) }.joined()
                }
            }
            return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
        }

        let decodeURIBlock: @convention(block) (String) -> String = { text in
            return text.removingPercentEncoding ?? text
        }

        // java.timeFormat(millis)
        let timeFormatBlock: @convention(block) (Double) -> String = { millis in
            let date = Date(timeIntervalSince1970: millis > 100_000_000_000 ? millis / 1000 : millis)
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy/MM/dd HH:mm"
            return formatter.string(from: date)
        }

        // java.htmlFormat(str)：去掉标签
        let htmlFormatBlock: @convention(block) (String) -> String = { html in
            return HTMLTextExtractor.plainText(from: html)
        }

        let toastBlock: @convention(block) (String) -> Void = { message in
            print("[JSBridge][toast] \(message)")
        }

        javaObject?.setObject(ajaxBlock, forKeyedSubscript: "ajax" as NSString)
        javaObject?.setObject(getStringAsyncBlock, forKeyedSubscript: "getStringAsync" as NSString)
        javaObject?.setObject(putBlock, forKeyedSubscript: "put" as NSString)
        javaObject?.setObject(getBlock, forKeyedSubscript: "get" as NSString)
        javaObject?.setObject(logBlock, forKeyedSubscript: "log" as NSString)
        javaObject?.setObject(base64EncodeBlock, forKeyedSubscript: "base64Encode" as NSString)
        javaObject?.setObject(base64DecodeBlock, forKeyedSubscript: "base64Decode" as NSString)
        javaObject?.setObject(md5Block, forKeyedSubscript: "md5Encode" as NSString)
        javaObject?.setObject(md5ShortBlock, forKeyedSubscript: "md5Encode16" as NSString)
        javaObject?.setObject(decodeURIBlock, forKeyedSubscript: "decodeURI" as NSString)
        javaObject?.setObject(htmlFormatBlock, forKeyedSubscript: "htmlFormat" as NSString)
        javaObject?.setObject(toastBlock, forKeyedSubscript: "toast" as NSString)
        javaObject?.setObject(toastBlock, forKeyedSubscript: "longToast" as NSString)

        // 参数类型需要兜底的 API 用私有名注册，再由 JS 包装层统一转成字符串/数字，
        // 避免书源脚本传 undefined 时桥接层崩溃。
        javaObject?.setObject(ruleStringBlock, forKeyedSubscript: "__getString" as NSString)
        javaObject?.setObject(ruleElementsBlock, forKeyedSubscript: "__getElements" as NSString)
        javaObject?.setObject(postBlock, forKeyedSubscript: "__post" as NSString)
        javaObject?.setObject(ajaxAllBlock, forKeyedSubscript: "__ajaxAll" as NSString)
        javaObject?.setObject(encodeURIBlock, forKeyedSubscript: "__encodeURI" as NSString)
        javaObject?.setObject(timeFormatBlock, forKeyedSubscript: "__timeFormat" as NSString)

        jsContext.setValue(javaObject, forKey: "java")

        _ = jsContext.evaluateScript(
            """
            (function () {
                if (typeof java === 'undefined' || !java) { return; }
                function s(value) { return value === null || value === undefined ? '' : String(value); }
                java.getString = function (rule) { return java.__getString(s(rule)); };
                java.getElements = function (rule) {
                    var raw = java.__getElements(s(rule));
                    try { return JSON.parse(raw); } catch (e) { return []; }
                };
                java.post = function (url, body, headers) {
                    var payload = '';
                    if (headers) { payload = typeof headers === 'string' ? headers : JSON.stringify(headers); }
                    return java.__post(s(url), s(body), payload);
                };
                java.ajaxAll = function (urls) {
                    var raw = java.__ajaxAll(JSON.stringify(urls || []));
                    try { return JSON.parse(raw); } catch (e) { return []; }
                };
                java.encodeURI = function (text, enc) { return java.__encodeURI(s(text), s(enc)); };
                java.timeFormat = function (time) { return java.__timeFormat(Number(time) || 0); };
            })();
            """
        )
    }

    /// 解析 header 参数（JSON 字符串 → 字典）
    private func parseHeaders(_ json: String) -> [String: String]? {
        guard !json.isEmpty, let data = json.data(using: .utf8) else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var headers: [String: String] = [:]
        for (key, value) in object {
            headers[key] = "\(value)"
        }
        return headers.isEmpty ? nil : headers
    }

    private func injectSourceObject(into jsContext: JSContext) {
        let sourceObject = JSValue(newObjectIn: jsContext)
        jsContext.setValue(sourceObject, forKey: "source")

        let getSourceUrl: @convention(block) () -> String = {
            return self.context?.source?.bookSourceUrl ?? ""
        }

        let getSourceName: @convention(block) () -> String = {
            return self.context?.source?.bookSourceName ?? ""
        }

        let getLoginUrl: @convention(block) () -> String = {
            return self.context?.source?.loginUrl ?? ""
        }

        let getHeader: @convention(block) () -> String = {
            return self.context?.source?.header ?? ""
        }

        jsContext.setValue(getSourceUrl, forKey: "__legado_source_bookSourceUrl")
        jsContext.setValue(getSourceName, forKey: "__legado_source_bookSourceName")
        jsContext.setValue(getLoginUrl, forKey: "__legado_source_loginUrl")
        jsContext.setValue(getHeader, forKey: "__legado_source_header")

        _ = jsContext.evaluateScript(
            """
            if (typeof source === 'undefined') { source = {}; }
            Object.defineProperty(source, 'bookSourceUrl', { configurable: true, enumerable: true, get: __legado_source_bookSourceUrl });
            Object.defineProperty(source, 'bookSourceName', { configurable: true, enumerable: true, get: __legado_source_bookSourceName });
            Object.defineProperty(source, 'loginUrl', { configurable: true, enumerable: true, get: __legado_source_loginUrl });
            Object.defineProperty(source, 'header', { configurable: true, enumerable: true, get: __legado_source_header });
            """
        )
    }

    private func injectCookieObject(into jsContext: JSContext) {
        let cookieObject = JSValue(newObjectIn: jsContext)

        let getCookieBlock: @convention(block) (String) -> String = { url in
            guard let cookieURL = URL(string: url),
                  let cookies = HTTPCookieStorage.shared.cookies(for: cookieURL),
                  !cookies.isEmpty else {
                return ""
            }

            return cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        }

        let setCookieBlock: @convention(block) (String, String) -> Void = { url, cookie in
            guard let cookieURL = URL(string: url), !cookie.isEmpty else { return }

            let parsedCookies = HTTPCookie.cookies(
                withResponseHeaderFields: ["Set-Cookie": cookie],
                for: cookieURL
            )

            if parsedCookies.isEmpty {
                if let simpleCookie = JSBridge.makeSimpleCookie(cookie, for: cookieURL) {
                    HTTPCookieStorage.shared.setCookie(simpleCookie)
                }
                return
            }

            for item in parsedCookies {
                HTTPCookieStorage.shared.setCookie(item)
            }
        }

        let removeCookieBlock: @convention(block) (String) -> Void = { url in
            guard let cookieURL = URL(string: url),
                  let cookies = HTTPCookieStorage.shared.cookies(for: cookieURL) else {
                return
            }

            for item in cookies {
                HTTPCookieStorage.shared.deleteCookie(item)
            }
        }

        cookieObject?.setObject(getCookieBlock, forKeyedSubscript: "get" as NSString)
        cookieObject?.setObject(setCookieBlock, forKeyedSubscript: "set" as NSString)
        cookieObject?.setObject(removeCookieBlock, forKeyedSubscript: "remove" as NSString)

        jsContext.setValue(cookieObject, forKey: "cookie")
    }

    private func parseSourceHeaders() -> [String: String]? {
        guard let headerString = context?.source?.header,
              let data = headerString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }

        if let headers = json as? [String: String] {
            return headers
        }

        if let dict = json as? [String: Any] {
            var headers: [String: String] = [:]
            for (key, value) in dict {
                headers[key] = "\(value)"
            }
            return headers.isEmpty ? nil : headers
        }

        return nil
    }

    private static func makeSimpleCookie(_ cookie: String, for url: URL) -> HTTPCookie? {
        guard let rawPair = cookie.split(separator: ";", maxSplits: 1).first else {
            return nil
        }

        let pair = rawPair.trimmingCharacters(in: .whitespacesAndNewlines)
        let segments = pair.split(separator: "=", maxSplits: 1).map(String.init)

        guard segments.count == 2,
              let host = url.host,
              !segments[0].isEmpty else {
            return nil
        }

        let properties: [HTTPCookiePropertyKey: Any] = [
            .name: segments[0],
            .value: segments[1],
            .domain: host,
            .path: "/"
        ]

        return HTTPCookie(properties: properties)
    }
}

class JSBridgeHTTPClient {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 10
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    static func syncGet(url: String, headers: [String: String]?) -> String? {
        guard let request = makeRequest(url: url, headers: headers) else {
            return nil
        }
        return perform(request)
    }

    /// 同步 POST（java.post 使用）
    static func syncPost(url: String, body: String, headers: [String: String]?) -> String? {
        guard var request = makeRequest(url: url, headers: headers) else {
            return nil
        }

        request.httpMethod = "POST"
        request.httpBody = body.data(using: .utf8)
        if request.value(forHTTPHeaderField: "Content-Type") == nil {
            request.setValue("application/x-www-form-urlencoded; charset=UTF-8",
                             forHTTPHeaderField: "Content-Type")
        }
        return perform(request)
    }

    private static func perform(_ request: URLRequest) -> String? {
        let semaphore = DispatchSemaphore(value: 0)
        var output: String?
        var task: URLSessionDataTask?

        task = session.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }

            if let error {
                print("[JSBridgeHTTPClient] syncGet error: \(error.localizedDescription)")
                return
            }

            guard let data else {
                return
            }

            if let response = response as? HTTPURLResponse,
               !(200..<300).contains(response.statusCode) {
                print("[JSBridgeHTTPClient] syncGet status: \(response.statusCode)")
                return
            }

            output = decode(data: data, response: response)
        }

        task?.resume()

        let timeout = DispatchTime.now() + .seconds(10)
        if semaphore.wait(timeout: timeout) == .timedOut {
            task?.cancel()
            print("[JSBridgeHTTPClient] syncGet timeout: \(request.url?.absoluteString ?? "")")
            return nil
        }

        return output
    }

    static func asyncGet(
        url: String,
        headers: [String: String]?,
        completion: @escaping (String?) -> Void
    ) {
        guard let request = makeRequest(url: url, headers: headers) else {
            completion(nil)
            return
        }

        session.dataTask(with: request) { data, response, error in
            if let error {
                print("[JSBridgeHTTPClient] asyncGet error: \(error.localizedDescription)")
                completion(nil)
                return
            }

            guard let data else {
                completion(nil)
                return
            }

            if let response = response as? HTTPURLResponse,
               !(200..<300).contains(response.statusCode) {
                print("[JSBridgeHTTPClient] asyncGet status: \(response.statusCode)")
                completion(nil)
                return
            }

            completion(decode(data: data, response: response))
        }.resume()
    }

    private static func makeRequest(url: String, headers: [String: String]?) -> URLRequest? {
        guard let targetURL = URL(string: url) else {
            return nil
        }

        var request = URLRequest(url: targetURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 10

        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 16_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.5 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")

        headers?.forEach { key, value in
            request.setValue(value, forHTTPHeaderField: key)
        }

        return request
    }

    private static func decode(data: Data, response: URLResponse?) -> String? {
        if let httpResponse = response as? HTTPURLResponse,
           let encodingName = httpResponse.textEncodingName {
            let cfEncoding = CFStringConvertIANACharSetNameToEncoding(encodingName as CFString)
            if cfEncoding != kCFStringEncodingInvalidId {
                let nsEncoding = CFStringConvertEncodingToNSStringEncoding(cfEncoding)
                if let text = String(data: data, encoding: String.Encoding(rawValue: nsEncoding)) {
                    return text
                }
            }
        }

        if let text = String(data: data, encoding: .utf8) {
            return text
        }

        return String(data: data, encoding: .isoLatin1)
    }
}
