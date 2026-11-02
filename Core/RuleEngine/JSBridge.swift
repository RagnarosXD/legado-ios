import Foundation
import JavaScriptCore
import CryptoKit

#if os(iOS)
import CommonCrypto
#endif

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

        // java.getString(rule) / java.getElements(rule)：在"当前页面上下文"上求值
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
        // Android JsExtensions.connect()：语义与 ajax 相同（返回响应体字符串）
        javaObject?.setObject(ajaxBlock, forKeyedSubscript: "connect" as NSString)
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

        jsContext.setObject(javaObject, forKeyedSubscript: "java" as NSString)

        // 扩展 API 必须在 java 全局对象建立之后注入（内部还有一层 JS 包装）
        injectExtendedAPIs(into: javaObject)

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
        jsContext.setObject(sourceObject, forKeyedSubscript: "source" as NSString)

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

        jsContext.setObject(getSourceUrl, forKeyedSubscript: "__legado_source_bookSourceUrl" as NSString)
        jsContext.setObject(getSourceName, forKeyedSubscript: "__legado_source_bookSourceName" as NSString)
        jsContext.setObject(getLoginUrl, forKeyedSubscript: "__legado_source_loginUrl" as NSString)
        jsContext.setObject(getHeader, forKeyedSubscript: "__legado_source_header" as NSString)

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

        jsContext.setObject(cookieObject, forKeyedSubscript: "cookie" as NSString)
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

extension JSBridge {

    /// 对齐 Android JsExtensions / JsEncodeUtils 的其余高频 API（1.3.10）
    /// 新增：setLocal、hex、bytes、digest、HMAC、AES/DES/3DES、timeFormatUTC、
    ///      toNumChapter、randomUUID、logType、cookie、文本文件读写
    func injectExtendedAPIs(into javaObject: JSValue?) {
        guard let javaObject else { return }
        let context = self.context

        // setLocal：仅本次规则链内可见（Android AnalyzeRule.setLocal）
        let setLocalBlock: @convention(block) (String, String) -> String = { key, value in
            context?.variables[key] = value
            return value
        }
        javaObject.setObject(setLocalBlock, forKeyedSubscript: "setLocal" as NSString)

        // hex / 字节
        let hexEncodeBlock: @convention(block) (String) -> String = { text in
            CryptoSupport.hexEncode(text)
        }
        javaObject.setObject(hexEncodeBlock, forKeyedSubscript: "hexEncodeToString" as NSString)

        let hexDecodeBlock: @convention(block) (String) -> String = { hex in
            CryptoSupport.hexDecodeToString(hex)
        }
        javaObject.setObject(hexDecodeBlock, forKeyedSubscript: "hexDecodeToString" as NSString)

        let strToBytesBlock: @convention(block) (String) -> String = { text in
            let numbers = Array(text.utf8).map { Int($0) }
            let data = (try? JSONSerialization.data(withJSONObject: numbers)) ?? Data()
            return String(decoding: data, as: UTF8.self)
        }
        javaObject.setObject(strToBytesBlock, forKeyedSubscript: "__strToBytes" as NSString)

        let bytesToStrBlock: @convention(block) (String) -> String = { json in
            guard let data = json.data(using: .utf8),
                  let numbers = try? JSONSerialization.jsonObject(with: data) as? [NSNumber] else {
                return ""
            }
            return String(decoding: numbers.map { $0.uint8Value }, as: UTF8.self)
        }
        javaObject.setObject(bytesToStrBlock, forKeyedSubscript: "__bytesToStr" as NSString)

        // 摘要
        let digestHexBlock: @convention(block) (String, String) -> String = { text, algorithm in
            CryptoSupport.digestHex(text, algorithm: algorithm)
        }
        javaObject.setObject(digestHexBlock, forKeyedSubscript: "digestHex" as NSString)

        let digestBase64Block: @convention(block) (String, String) -> String = { text, algorithm in
            CryptoSupport.digestBase64(text, algorithm: algorithm)
        }
        javaObject.setObject(digestBase64Block, forKeyedSubscript: "digestBase64Str" as NSString)

        let hmacHexBlock: @convention(block) (String, String, String) -> String = { text, algorithm, key in
            CryptoSupport.hmacHex(text, algorithm: algorithm, key: key)
        }
        javaObject.setObject(hmacHexBlock, forKeyedSubscript: "HMacHex" as NSString)

        let hmacBase64Block: @convention(block) (String, String, String) -> String = { text, algorithm, key in
            CryptoSupport.hmacBase64(text, algorithm: algorithm, key: key)
        }
        javaObject.setObject(hmacBase64Block, forKeyedSubscript: "HMacBase64" as NSString)

        // 对称加解密（AES / DES / 3DES，ECB/CBC + PKCS7）
        let aesDecodeBlock: @convention(block) (String, String, String, String) -> String = { data, key, transformation, iv in
            CryptoSupport.symmetricDecryptBase64(data, key: key, transformation: transformation, iv: iv)
        }
        javaObject.setObject(aesDecodeBlock, forKeyedSubscript: "aesBase64DecodeToString" as NSString)

        let aesDecodeRawBlock: @convention(block) (String, String, String, String) -> String = { data, key, transformation, iv in
            CryptoSupport.symmetricDecrypt(data, key: key, transformation: transformation, iv: iv)
        }
        javaObject.setObject(aesDecodeRawBlock, forKeyedSubscript: "aesDecodeToString" as NSString)

        let aesEncodeBlock: @convention(block) (String, String, String, String) -> String = { text, key, transformation, iv in
            CryptoSupport.symmetricEncryptBase64(text, key: key, transformation: transformation, iv: iv)
        }
        javaObject.setObject(aesEncodeBlock, forKeyedSubscript: "aesEncodeToBase64String" as NSString)

        let aesEncodeRawBlock: @convention(block) (String, String, String, String) -> String = { text, key, transformation, iv in
            CryptoSupport.symmetricEncrypt(text, key: key, transformation: transformation, iv: iv)
        }
        javaObject.setObject(aesEncodeRawBlock, forKeyedSubscript: "aesEncodeToString" as NSString)

        javaObject.setObject(aesDecodeBlock, forKeyedSubscript: "desBase64DecodeToString" as NSString)
        javaObject.setObject(aesDecodeRawBlock, forKeyedSubscript: "desDecodeToString" as NSString)
        javaObject.setObject(aesEncodeBlock, forKeyedSubscript: "desEncodeToBase64String" as NSString)
        javaObject.setObject(aesEncodeRawBlock, forKeyedSubscript: "desEncodeToString" as NSString)
        javaObject.setObject(aesDecodeBlock, forKeyedSubscript: "tripleDESDecodeArgsBase64Str" as NSString)
        javaObject.setObject(aesEncodeBlock, forKeyedSubscript: "tripleDESEncodeArgsBase64Str" as NSString)

        // 时间（带时区）
        let timeFormatUTCBlock: @convention(block) (Double, String, Double) -> String = { time, format, offset in
            CryptoSupport.formatTimeUTC(milliseconds: time, format: format, hourOffset: offset)
        }
        javaObject.setObject(timeFormatUTCBlock, forKeyedSubscript: "timeFormatUTC" as NSString)

        // 章节号中文数字 → 阿拉伯数字
        let toNumChapterBlock: @convention(block) (String) -> String = { text in
            CryptoSupport.normalizeChapterNumber(text)
        }
        javaObject.setObject(toNumChapterBlock, forKeyedSubscript: "toNumChapter" as NSString)

        // UUID / logType
        let uuidBlock: @convention(block) () -> String = {
            UUID().uuidString
        }
        javaObject.setObject(uuidBlock, forKeyedSubscript: "randomUUID" as NSString)

        let logTypeBlock: @convention(block) (Any?) -> Void = { value in
            AppLogger.debug("JS", "logType: \(String(describing: value))")
        }
        javaObject.setObject(logTypeBlock, forKeyedSubscript: "logType" as NSString)

        // cookie
        let cookieBlock: @convention(block) (String) -> String = { url in
            guard let cookieURL = URL(string: url) else { return "" }
            let cookies = HTTPCookieStorage.shared.cookies(for: cookieURL) ?? []
            return cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        }
        javaObject.setObject(cookieBlock, forKeyedSubscript: "getCookie" as NSString)

        // 文本文件（限定在 Documents 下，防目录穿越）
        let readFileBlock: @convention(block) (String) -> String = { path in
            FileSandbox.readText(relativePath: path) ?? ""
        }
        javaObject.setObject(readFileBlock, forKeyedSubscript: "readTxtFile" as NSString)
        javaObject.setObject(readFileBlock, forKeyedSubscript: "readFile" as NSString)

        let writeFileBlock: @convention(block) (String, String) -> Bool = { path, content in
            FileSandbox.writeText(relativePath: path, content: content)
        }
        javaObject.setObject(writeFileBlock, forKeyedSubscript: "writeTxtFile" as NSString)

        let deleteFileBlock: @convention(block) (String) -> Bool = { path in
            FileSandbox.delete(relativePath: path)
        }
        javaObject.setObject(deleteFileBlock, forKeyedSubscript: "deleteFile" as NSString)

        // JS 包装：getStringList / getElement 复用 __getElements
        _ = context?.jsContext?.evaluateScript(
            """
            (function () {
                if (typeof java === 'undefined' || !java) { return; }
                function s(value) { return value === null || value === undefined ? '' : String(value); }
                java.getStringList = function (rule) {
                    var raw = java.__getElements(s(rule));
                    try { return JSON.parse(raw); } catch (e) { return []; }
                };
                java.getElement = function (rule) {
                    var raw = java.__getElements(s(rule));
                    try { var list = JSON.parse(raw); return list.length ? list[0] : null; } catch (e) { return null; }
                };
                java.strToBytes = function (text) {
                    try { return JSON.parse(java.__strToBytes(s(text))); } catch (e) { return []; }
                };
                java.bytesToStr = function (arr) {
                    try { return java.__bytesToStr(JSON.stringify(arr || [])); } catch (e) { return ''; }
                };
                java.log = (function (original) {
                    return function (msg) { if (original) { original(s(msg)); } return msg; };
                })(java.log);
            })();
            """
        )
    }
}

// MARK: - 加密 / 编码工具（对齐 JsEncodeUtils）

enum CryptoSupport {

    // MARK: Hex

    static func hexEncode(_ text: String) -> String {
        text.utf8.map { String(format: "%02x", $0) }.joined()
    }

    static func hexDecodeToString(_ hex: String) -> String {
        let cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count % 2 == 0 else { return "" }

        var bytes: [UInt8] = []
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return "" }
            bytes.append(byte)
            index = next
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    // MARK: 摘要

    static func digestHex(_ text: String, algorithm: String) -> String {
        digest(text, algorithm: algorithm).map { $0.map { String(format: "%02x", $0) }.joined() } ?? ""
    }

    static func digestBase64(_ text: String, algorithm: String) -> String {
        digest(text, algorithm: algorithm)?.base64EncodedString() ?? ""
    }

    static func digest(_ text: String, algorithm: String) -> Data? {
        let data = Data(text.utf8)
        let name = algorithm.uppercased()

        #if os(iOS)
        switch name {
        case "SHA-1", "SHA1":
            return Data(Insecure.SHA1.hash(data: data))
        case "SHA-256", "SHA256":
            return Data(SHA256.hash(data: data))
        case "SHA-384", "SHA384":
            return Data(SHA384.hash(data: data))
        case "SHA-512", "SHA512":
            return Data(SHA512.hash(data: data))
        default:
            break
        }
        #endif

        return commonCryptDigest(data, algorithm: name)
    }

    // MARK: HMAC

    static func hmacHex(_ text: String, algorithm: String, key: String) -> String {
        hmac(text, algorithm: algorithm, key: key).map { $0.map { String(format: "%02x", $0) }.joined() } ?? ""
    }

    static func hmacBase64(_ text: String, algorithm: String, key: String) -> String {
        hmac(text, algorithm: algorithm, key: key)?.base64EncodedString() ?? ""
    }

    static func hmac(_ text: String, algorithm: String, key: String) -> Data? {
        let data = Data(text.utf8)
        let keyData = Data(key.utf8)

        #if os(iOS)
        let name = algorithm.uppercased()
        switch name {
        case "HmacSHA1", "SHA-1", "SHA1", "HmacSHA-1":
            return Data(HMAC<Insecure.SHA1>.authenticationCode(for: data, using: SymmetricKey(data: keyData)))
        case "HmacSHA256", "SHA-256", "SHA256", "HmacSHA-256":
            return Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: keyData)))
        case "HmacSHA384", "SHA-384", "SHA384":
            return Data(HMAC<SHA384>.authenticationCode(for: data, using: SymmetricKey(data: keyData)))
        case "HmacSHA512", "SHA-512", "SHA512":
            return Data(HMAC<SHA512>.authenticationCode(for: data, using: SymmetricKey(data: keyData)))
        default:
            break
        }
        #endif

        return commonCryptHMAC(data, algorithm: algorithm, key: keyData)
    }

    // MARK: 对称加解密

    static func symmetricDecryptBase64(_ data: String, key: String, transformation: String, iv: String) -> String {
        guard let cipher = Data(base64Encoded: data.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return ""
        }
        return symmetricDecrypt(cipher, key: key, transformation: transformation, iv: iv)
    }

    static func symmetricDecrypt(_ data: String, key: String, transformation: String, iv: String) -> String {
        let cipher = hexToData(data) ?? Data(base64Encoded: data) ?? Data()
        guard let plain = crypt(encrypt: false, data: cipher, key: key, transformation: transformation, iv: iv) else {
            return ""
        }
        return String(decoding: plain, as: UTF8.self)
    }

    static func symmetricDecrypt(_ data: Data, key: String, transformation: String, iv: String) -> String {
        guard let plain = crypt(encrypt: false, data: data, key: key, transformation: transformation, iv: iv) else {
            return ""
        }
        return String(decoding: plain, as: UTF8.self)
    }

    static func symmetricEncryptBase64(_ text: String, key: String, transformation: String, iv: String) -> String {
        guard let cipher = crypt(encrypt: true, data: Data(text.utf8), key: key, transformation: transformation, iv: iv) else {
            return ""
        }
        return cipher.base64EncodedString()
    }

    static func symmetricEncrypt(_ text: String, key: String, transformation: String, iv: String) -> String {
        guard let cipher = crypt(encrypt: true, data: Data(text.utf8), key: key, transformation: transformation, iv: iv) else {
            return ""
        }
        return cipher.map { String(format: "%02x", $0) }.joined()
    }

    private static func hexToData(_ hex: String) -> Data? {
        let cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned.count % 2 == 0,
              cleaned.range(of: "^[0-9a-fA-F]+$", options: .regularExpression) != nil else {
            return nil
        }
        var data = Data()
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }

    // MARK: 时间与文本

    static func formatTimeUTC(milliseconds: Double, format: String, hourOffset: Double) -> String {
        let date = Date(timeIntervalSince1970: milliseconds / 1000)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format.isEmpty ? "yyyy/MM/dd HH:mm" : format
        formatter.timeZone = TimeZone(secondsFromGMT: Int(hourOffset * 3600))
        return formatter.string(from: date)
    }

    /// 章节号归一化：中文数字/全角数字 → 阿拉伯数字（对齐 Android toNumChapter）
    static func normalizeChapterNumber(_ text: String) -> String {
        var result = text
        let digits: [Character: Int] = [
            "零": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5,
            "六": 6, "七": 7, "八": 8, "九": 9
        ]
        let units: [Character: Int] = ["十": 10, "百": 100, "千": 1000, "万": 10000]

        // 全角数字
        for (full, ascii) in zip("０１２３４５６７８９", "0123456789") {
            result = result.replacingOccurrences(of: String(full), with: String(ascii))
        }

        // 简单中文数字（<= 9999）
        var total = 0
        var section = 0
        var number = 0
        var converted = false

        for char in result {
            if let value = digits[char] {
                number = value
                converted = true
            } else if let unit = units[char] {
                section += (number == 0 ? 1 : number) * unit
                number = 0
                converted = true
            } else if char.isNumber {
                number = number * 10 + (Int(String(char)) ?? 0)
            }
        }

        guard converted else { return result }

        total = section + number
        if total <= 0 { return result }

        // 只替换连续的「中文数字 + 单位」片段，保留其余文字
        let pattern = "[零一二两三四五六七八九十百千万]+"
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "\(total)")
        }
        return result
    }

    // MARK: CommonCrypto 兜底（Linux 上为空实现）

    #if os(iOS)
    private static func commonCryptDigest(_ data: Data, algorithm: String) -> Data? {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        let nsData = data as NSData

        switch algorithm {
        case "MD5":
            CC_MD5(nsData.bytes, CC_LONG(nsData.length), &digest)
            return Data(digest.prefix(Int(CC_MD5_DIGEST_LENGTH)))
        case "SHA-1", "SHA1":
            CC_SHA1(nsData.bytes, CC_LONG(nsData.length), &digest)
            return Data(digest.prefix(Int(CC_SHA1_DIGEST_LENGTH)))
        default:
            return nil
        }
    }

    private static func commonCryptHMAC(_ data: Data, algorithm: String, key: Data) -> Data? {
        let algorithmName = algorithm.uppercased()
        let ccAlgorithm: CCHmacAlgorithm

        switch algorithmName {
        case "HMACSHA1", "SHA-1", "SHA1", "HMACSHA-1":
            ccAlgorithm = CCHmacAlgorithm(kCCHmacAlgSHA1)
        case "HMACSHA256", "SHA-256", "SHA256", "HMACSHA-256":
            ccAlgorithm = CCHmacAlgorithm(kCCHmacAlgSHA256)
        case "HMACSHA512", "SHA-512", "SHA512":
            ccAlgorithm = CCHmacAlgorithm(kCCHmacAlgSHA512)
        default:
            return nil
        }

        let digestLength = ccAlgorithm == CCHmacAlgorithm(kCCHmacAlgSHA1) ? Int(CC_SHA1_DIGEST_LENGTH)
            : (ccAlgorithm == CCHmacAlgorithm(kCCHmacAlgSHA256) ? Int(CC_SHA256_DIGEST_LENGTH) : Int(CC_SHA512_DIGEST_LENGTH))

        var result = [UInt8](repeating: 0, count: digestLength)
        data.withUnsafeBytes { dataBytes in
            key.withUnsafeBytes { keyBytes in
                CCHmac(
                    ccAlgorithm,
                    keyBytes.baseAddress,
                    key.count,
                    dataBytes.baseAddress,
                    data.count,
                    &result
                )
            }
        }
        return Data(result)
    }

    private static func crypt(
        encrypt: Bool,
        data: Data,
        key: String,
        transformation: String,
        iv: String
    ) -> Data? {
        let upper = transformation.uppercased()
        let algorithm: CCAlgorithm
        if upper.contains("DESEDE") || upper.contains("3DES") {
            algorithm = CCAlgorithm(kCCAlgorithm3DES)
        } else if upper.contains("DES") {
            algorithm = CCAlgorithm(kCCAlgorithmDES)
        } else {
            algorithm = CCAlgorithm(kCCAlgorithmAES)
        }

        let options = CCOptions(kCCOptionPKCS7Padding)
            | (upper.contains("ECB") ? CCOptions(kCCOptionECBMode) : 0)

        var keyData = Data(key.utf8)
        var ivData = Data(iv.utf8)

        switch algorithm {
        case CCAlgorithm(kCCAlgorithmAES):
            if keyData.count < kCCKeySizeAES128 { keyData = padded(keyData, to: kCCKeySizeAES128) }
            ivData = padded(ivData, to: kCCBlockSizeAES128, zeroIfEmpty: true)
        case CCAlgorithm(kCCAlgorithmDES):
            keyData = padded(keyData, to: kCCKeySizeDES)
            ivData = padded(ivData, to: kCCBlockSizeDES, zeroIfEmpty: true)
        default:
            keyData = padded(keyData, to: kCCKeySize3DES)
            ivData = padded(ivData, to: kCCBlockSize3DES, zeroIfEmpty: true)
        }

        let outLength = data.count + kCCBlockSizeAES128
        var output = [UInt8](repeating: 0, count: outLength)
        var actualLength = 0

        let status = data.withUnsafeBytes { dataBytes -> CCCryptorStatus in
            keyData.withUnsafeBytes { keyBytes in
                ivData.withUnsafeBytes { ivBytes in
                    CCCrypt(
                        CCOperation(encrypt ? kCCEncrypt : kCCDecrypt),
                        algorithm,
                        options,
                        keyBytes.baseAddress,
                        keyData.count,
                        upper.contains("ECB") ? nil : ivBytes.baseAddress,
                        dataBytes.baseAddress,
                        data.count,
                        &output,
                        outLength,
                        &actualLength
                    )
                }
            }
        }

        guard status == kCCSuccess else { return nil }
        return Data(output.prefix(actualLength))
    }

    private static func padded(_ data: Data, to length: Int, zeroIfEmpty: Bool = false) -> Data {
        if data.isEmpty && zeroIfEmpty {
            return Data(repeating: 0, count: length)
        }
        if data.count >= length {
            return Data(data.prefix(length))
        }
        return data + Data(repeating: 0, count: length - data.count)
    }
    #else
    private static func commonCryptDigest(_ data: Data, algorithm: String) -> Data? { nil }
    private static func commonCryptHMAC(_ data: Data, algorithm: String, key: Data) -> Data? { nil }
    private static func crypt(encrypt: Bool, data: Data, key: String, transformation: String, iv: String) -> Data? { nil }
    #endif
}

// MARK: - 受限文件访问（对齐 Android getFile/readTxtFile 的相对路径语义）

enum FileSandbox {
    private static var root: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private static func resolve(_ relativePath: String) -> URL? {
        let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/") else { return nil }
        let url = root.appendingPathComponent(trimmed).standardizedFileURL
        guard url.path.hasPrefix(root.standardizedFileURL.path) else { return nil }
        return url
    }

    static func readText(relativePath: String) -> String? {
        guard let url = resolve(relativePath) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    static func writeText(relativePath: String, content: String) -> Bool {
        guard let url = resolve(relativePath) else { return false }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (try? content.write(to: url, atomically: true, encoding: .utf8)) != nil
    }

    static func delete(relativePath: String) -> Bool {
        guard let url = resolve(relativePath) else { return false }
        return (try? FileManager.default.removeItem(at: url)) != nil
    }
}