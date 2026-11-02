//
//  RuleEngine.swift
//  Legado-iOS
//
//  书源规则解析引擎
//

import Foundation
import JavaScriptCore
import SwiftSoup
import Kanna

// MARK: - 元素上下文（用于列表项提取）
class ElementContext {
    var element: Any      // SwiftSoup.Element, JSON dict, 或 String
    var baseUrl: String?
    /// 所属书源（JS 里的 source.* 需要）
    var source: BookSource?
    /// 书源变量：同一本书的多条规则之间共享（@put / @get / java.put）
    var variables: [String: String] = [:]
    /// XPath 命中的原始节点（保留节点身份，避免 toHTML 二次解析丢结构）
    var xpathNode: XMLElement?
    /// 初始结果：URL 规则里的 `@result` / JS 段需要拿到上一段的值
    var initialResult: String?

    init(element: Any, baseUrl: String? = nil, source: BookSource? = nil) {
        self.element = element
        self.baseUrl = baseUrl
        self.source = source
    }
}

// MARK: - 结果类型
enum RuleResult {
    case string(String)
    case list([String])
    case none
    
    var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }
    
    var list: [String]? {
        if case .list(let value) = self { return value }
        return nil
    }

    /// 统一取值：单值直接返回，多值按行拼接
    var text: String {
        switch self {
        case .string(let value):
            return value
        case .list(let values):
            return values.filter { !$0.isEmpty }.joined(separator: "\n")
        case .none:
            return ""
        }
    }
}

// MARK: - 执行上下文
class ExecutionContext {
    var document: Any?
    var jsonString: String?
    var jsonDict: [String: Any]?
    /// JSON 根节点（可能是数组，jsonDict 只能表示对象）
    var jsonRoot: Any?
    var baseURL: URL?
    var source: BookSource?
    var variables: [String: String] = [:]
    var lastResult: RuleResult = .none
    /// 原始 HTML：XPath 解析器需要字符串形态的文档
    var htmlString: String?
    /// 限定作用域的元素：字段规则要「在当前列表项内」查找，而不是整篇文档
    var scopedElement: SwiftSoup.Element?
    
    /// JavaScriptCore 的 init 是可失败的（`JSContext()` 返回 `JSContext?`），
    /// 在多书源并发搜索、首次创建 VM 时偶发返回 nil。之前直接 `JSContext()!` 强解包，
    /// 一旦返回 nil 就是必崩。这里改为「串行创建 + 短暂重试 + 可选」，失败时由调用方抛错。
    lazy var jsContext: JSContext? = {
        ExecutionContext.makeJSContext(owner: self)
    }()

    private static let jsContextLock = NSLock()

    private static func makeJSContext(owner: ExecutionContext) -> JSContext? {
        jsContextLock.lock()
        defer { jsContextLock.unlock() }

        var created: JSContext?
        for attempt in 0..<3 {
            if let context = JSContext() {
                created = context
                break
            }
            if attempt < 2 {
                Thread.sleep(forTimeInterval: 0.02)
            }
        }

        guard let context = created else {
            AppLogger.error("JS", "JSContext 创建失败（已重试 3 次），本轮规则将无法执行 JS")
            return nil
        }

        let bridge = JSBridge()
        bridge.context = owner
        bridge.inject(into: context)

        // 注入 getVar / setVar / result
        // 必须显式声明为 @convention(block)：直接传 Swift 闭包给 setObject 不会被桥接成 JS function
        let getVarBlock: @convention(block) (String) -> String = { [weak owner] key in
            owner?.variables[key] ?? ""
        }
        let setVarBlock: @convention(block) (String, String) -> Void = { [weak owner] key, value in
            owner?.variables[key] = value
        }
        let resultBlock: @convention(block) () -> String = { [weak owner] in
            owner?.lastResult.string ?? ""
        }

        context.setObject(getVarBlock, forKeyedSubscript: "getVar" as NSString)
        context.setObject(setVarBlock, forKeyedSubscript: "setVar" as NSString)
        context.setObject(resultBlock, forKeyedSubscript: "result" as NSString)

        return context
    }
}

// MARK: - 解析器协议
protocol RuleExecutor {
    var kind: RuleKind { get }
    func canExecute(_ rule: String) -> Bool
    func execute(_ rule: String, context: ExecutionContext) throws -> RuleResult
}

enum RuleKind: String, CaseIterable {
    case jsonPath = "json"
    case xpath = "xpath"
    case css = "css"
    case regex = "regex"
    case js = "js"
}

// MARK: - 规则引擎
class RuleEngine {
    private var executors: [RuleExecutor] = []
    
    init() {
        // 按优先级注册解析器
        executors.append(JSONPathParser())
        executors.append(XPathParser())
        executors.append(CSSParser())
        executors.append(RegexParser())
        executors.append(JavaScriptParser())
    }
    
    func execute(
        rules: [String],
        context: ExecutionContext
    ) throws -> RuleResult {
        var lastResult: RuleResult = .none
        
        for rule in rules {
            do {
                lastResult = try executeWithSplit(rule, context: context)
                context.lastResult = lastResult
            } catch {
                print("规则执行错误 [\(rule)]: \(error)")
            }
        }
        
        return lastResult
    }
    
    func executeSingle(
        rule: String,
        context: ExecutionContext
    ) throws -> RuleResult {
        let result = try executeWithSplit(rule, context: context)
        context.lastResult = result
        return result
    }

    private func executeWithSplit(_ rule: String, context: ExecutionContext) throws -> RuleResult {
        let trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .none }

        // 对齐 Android：@put 可出现在规则任意位置；先执行它，再用剩余规则继续求值
        let putExtraction = TemplateEngine.extractPuts(trimmed)
        if !putExtraction.puts.isEmpty {
            for block in putExtraction.puts {
                _ = TemplateEngine.executePut(block, context: context, ruleEngine: self)
            }
            let remain = putExtraction.rest.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !remain.isEmpty else { return context.lastResult }
            return try executeWithSplit(remain, context: context)
        }

        if let key = TemplateEngine.parseGet(trimmed) {
            let value = TemplateEngine.executeGet(key, context: context)
            return value.isEmpty ? .none : .string(value)
        }

        // 1) 先按 <js> / @js: 分段（Android splitSourceRule）：普通段结果作为后续段的内容
        let jsSegments = RuleSplitter.splitByJSSegments(trimmed)
        if jsSegments.count > 1 {
            return try executeJSSegments(jsSegments, context: context)
        }

        // 2) 组合符：种类由「最先出现」的分隔符决定，括号/引号内的分隔符不参与切分
        let combination = RuleSplitter.splitCombination(trimmed)
        switch combination.kind {
        case .or:
            return try executeOr(segments: combination.parts, context: context)
        case .and:
            return try executeAnd(segments: combination.parts, context: context)
        case .cross:
            return try executeCross(segments: combination.parts, context: context)
        case .single:
            break
        }

        guard let splitRule = RuleSplitter.split(trimmed).first else {
            throw RuleError.unsupportedRule(trimmed)
        }

        return try executeSplitRule(splitRule, context: context)
    }

    private func executeSplitRule(_ splitRule: SplitRule, context: ExecutionContext) throws -> RuleResult {
        let executor = executors.first(where: { $0.kind == splitRule.type })
            ?? executors.first(where: { $0.canExecute(splitRule.rule) })

        guard let executor else {
            throw RuleError.unsupportedRule(splitRule.rule)
        }

        let startedAt = Date()
        let result = try executor.execute(splitRule.rule, context: context)
        let cost = Int(Date().timeIntervalSince(startedAt) * 1000)

        // 慢规则 / 超长规则：崩溃前能看到到底卡在哪条规则上
        if cost > 300 || splitRule.rule.count > 500 {
            AppLogger.warn("Rule", "慢规则 \(executor.kind.rawValue) \(cost)ms len=\(splitRule.rule.count) rule=\(splitRule.rule.prefix(140))")
        }

        return try applyReplace(splitRule.replace, to: result)
    }

    private func executeAnd(segments: [String], context: ExecutionContext) throws -> RuleResult {
        var values: [String] = []

        for segment in segments {
            let result = try executeWithSplit(segment, context: context)
            values.append(contentsOf: flatten(result))
            context.lastResult = result
        }

        if values.isEmpty { return .none }
        // Android 文本结果是 \n 连接（AnalyzeByJSoup.getString 多结果 join）
        return .string(values.joined(separator: "\n"))
    }

    private func executeOr(segments: [String], context: ExecutionContext) throws -> RuleResult {
        for segment in segments {
            let result = try executeWithSplit(segment, context: context)
            context.lastResult = result
            if !isEmpty(result) {
                return result
            }
        }

        return .none
    }

    /// `%%`：按下标交叉合并（Android AnalyzeByJSoup.getResultList 的交叉语义）
    private func executeCross(segments: [String], context: ExecutionContext) throws -> RuleResult {
        var lists: [[String]] = []

        for segment in segments {
            let result = try executeWithSplit(segment, context: context)
            context.lastResult = result
            lists.append(flatten(result))
        }

        guard !lists.isEmpty else { return .none }

        var merged: [String] = []
        let maxCount = lists.map { $0.count }.max() ?? 0
        for index in 0..<maxCount {
            for list in lists where index < list.count {
                merged.append(list[index])
            }
        }

        return merged.isEmpty ? .none : .list(merged)
    }

    /// 逐段执行：普通段在「上一段结果」上继续解析，JS 段执行脚本并把结果交给下一段
    private func executeJSSegments(
        _ segments: [RuleSplitter.JSSegment],
        context: ExecutionContext
    ) throws -> RuleResult {
        var lastText: String?

        for segment in segments {
            if segment.isJS {
                if let lastText, let jsContext = context.jsContext {
                    jsContext.setObject(lastText, forKeyedSubscript: "result" as NSString)
                }
                let result = try executeWithSplit("@js:" + segment.text, context: context)
                lastText = result.text
                context.lastResult = result
                continue
            }

            if let previous = lastText {
                // 用上一段结果作为内容：HTML 重新 parse，JSON 直接作为 jsonString
                let next = ExecutionContext()
                next.baseURL = context.baseURL
                next.source = context.source
                next.variables = context.variables
                next.htmlString = previous

                let payload = previous.trimmingCharacters(in: .whitespacesAndNewlines)
                if payload.hasPrefix("{") || payload.hasPrefix("[") {
                    next.jsonString = previous
                } else {
                    next.document = try? SwiftSoup.parse(previous)
                }

                let result = try executeWithSplit(segment.text, context: next)
                context.variables = next.variables
                lastText = result.text
                context.lastResult = result
            } else {
                let result = try executeWithSplit(segment.text, context: context)
                lastText = result.text
                context.lastResult = result
            }
        }

        return context.lastResult
    }

    private func executeFormat(segments: [String], context: ExecutionContext) throws -> RuleResult {
        guard let source = segments.first else { return .none }

        let sourceResult = try executeWithSplit(source, context: context)
        var value = flatten(sourceResult).joined()

        if value.isEmpty {
            return .none
        }

        for template in segments.dropFirst() {
            value = applyFormat(template, value: value)
        }

        return value.isEmpty ? .none : .string(value)
    }

    private func applyFormat(_ template: String, value: String) -> String {
        if template.contains("{0}") {
            return template.replacingOccurrences(of: "{0}", with: value)
        }
        if template.contains("{{result}}") {
            return template.replacingOccurrences(of: "{{result}}", with: value)
        }
        if template.contains("%@") {
            return String(format: template, value)
        }
        if template.contains("%s") {
            return template.replacingOccurrences(of: "%s", with: value)
        }
        return template + value
    }

    private func applyReplace(
        _ replace: (pattern: String, replacement: String, group: Int?, replaceFirst: Bool)?,
        to result: RuleResult
    ) throws -> RuleResult {
        guard let replace else { return result }

        guard let regex = try? NSRegularExpression(pattern: replace.pattern) else {
            throw RuleError.invalidRule("无效替换正则：\(replace.pattern)")
        }

        let replacement = replace.replacement

        switch result {
        case .string(let value):
            if replace.replaceFirst {
                return .string(Self.replaceFirstMatch(in: value, regex: regex, template: replacement))
            }
            let range = NSRange(value.startIndex..., in: value)
            let replaced = regex.stringByReplacingMatches(in: value, range: range, withTemplate: replacement)
            return .string(replaced)
        case .list(let values):
            if replace.replaceFirst {
                return .list(values.map { Self.replaceFirstMatch(in: $0, regex: regex, template: replacement) })
            }
            let replacedValues = values.map { item in
                let range = NSRange(item.startIndex..., in: item)
                return regex.stringByReplacingMatches(in: item, range: range, withTemplate: replacement)
            }
            return .list(replacedValues)
        case .none:
            return .none
        }
    }

    /// 对齐 Android：只取第一个匹配的整段做替换，返回替换后的那一段；没有匹配返回空串
    private static func replaceFirstMatch(in value: String, regex: NSRegularExpression, template: String) -> String {
        let range = NSRange(value.startIndex..., in: value)
        guard let match = regex.firstMatch(in: value, range: range),
              let matchRange = Range(match.range, in: value) else {
            return ""
        }

        let segment = String(value[matchRange])
        let segmentRange = NSRange(segment.startIndex..., in: segment)
        return regex.stringByReplacingMatches(in: segment, range: segmentRange, withTemplate: template)
    }

    private func flatten(_ result: RuleResult) -> [String] {
        switch result {
        case .string(let value):
            return value.isEmpty ? [] : [value]
        case .list(let values):
            return values.filter { !$0.isEmpty }
        case .none:
            return []
        }
    }

    private func isEmpty(_ result: RuleResult) -> Bool {
        flatten(result).isEmpty
    }
    
    // MARK: - 从 HTML/JSON 中提取元素列表
    
    /// 提取元素列表（用于书籍列表、章节列表等）
    /// - Parameters:
    ///   - ruleStr: 列表规则，如 CSS 选择器 "div.book-item" 或 JSONPath "$.list"
    ///   - body: HTML 或 JSON 字符串
    ///   - baseUrl: 基础 URL
    /// - Returns: 元素上下文数组
    func getElements(ruleStr: String?, body: String, baseUrl: String?) throws -> [ElementContext] {
        guard let ruleStr, !ruleStr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }

        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let isJson = trimmedBody.hasPrefix("{") || trimmedBody.hasPrefix("[")
        var rule = ruleStr.trimmingCharacters(in: .whitespacesAndNewlines)
        var forceHTML = false

        // @json: 前缀可以强制走 JSON 解析（即使响应体是 HTML 片段包裹的 JSON）
        if rule.lowercased().hasPrefix("@json:") {
            return try getJsonElements(ruleStr: rule, body: body)
        }

        // @css: 前缀要剥掉，否则会被整条当成 CSS 选择器（"@css:.list" 永远选不中）
        if rule.lowercased().hasPrefix("@css:") {
            rule = String(rule.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
            forceHTML = true
        }

        // @xpath: 列表：用 libxml2 选节点，再把节点 HTML 交给字段规则
        if rule.lowercased().hasPrefix("@xpath:") {
            let xpath = String(rule.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
            return try getXPathElements(xpath: xpath, body: body, baseUrl: baseUrl)
        }

        // 规则本身是 JSONPath 时也必须按 JSON 解析：否则会被当成 CSS 选择器丢给 SwiftSoup，
        // 抛出 "SwiftSoup.Exception 错误 0"（日志里 $.data.chapters[*] 就是这么炸的）
        let looksLikeJSONPath = rule.hasPrefix("$.") || rule.hasPrefix("$[")
        // 有些源写 data.list 这种省略 $. 的路径：仅当响应体确实是 JSON 时按 JSON 处理
        let shorthandJSONPath = isJson && !forceHTML && !rule.hasPrefix("$")
            && rule.range(of: #"^[A-Za-z_][A-Za-z0-9_-]*(\.[A-Za-z0-9_*\[\]{}]+)+$"#, options: .regularExpression) != nil

        if !forceHTML && (isJson || looksLikeJSONPath || shorthandJSONPath) {
            let jsonRule = (shorthandJSONPath && !rule.hasPrefix("$")) ? "$." + rule : rule
            return try getJsonElements(ruleStr: jsonRule, body: body)
        }
        return try getHtmlElements(ruleStr: rule, body: body, baseUrl: baseUrl)
    }
    
    /// 从 HTML 用 XPath 提取元素列表
    private func getXPathElements(xpath: String, body: String, baseUrl: String?) throws -> [ElementContext] {
        guard XPathParser.isSafe(xpath) else {
            AppLogger.error("Rule", "XPath 列表表达式不合法：\(xpath.prefix(160))")
            throw RuleError.invalidRule("XPath 表达式不合法")
        }

        do {
            let doc = try Kanna.HTML(html: body, encoding: .utf8)

            var elements: [ElementContext] = []
            for node in doc.xpath(xpath) {
                let html = node.toHTML ?? ""
                // 属性节点 / 文本节点的 toHTML 为空，但 Android 会把它们的值作为结果
                guard !html.isEmpty || node.text != nil else { continue }
                let ctx = ElementContext(element: html, baseUrl: baseUrl)
                ctx.xpathNode = node
                elements.append(ctx)
            }
            return elements
        } catch {
            AppLogger.error("Rule", "XPath 列表解析失败 err=\(error)")
            throw RuleError.noDocument
        }
    }

    /// 从 HTML 提取元素列表
    private func getHtmlElements(ruleStr: String, body: String, baseUrl: String?) throws -> [ElementContext] {
        let doc: SwiftSoup.Document
        do {
            doc = try SwiftSoup.parse(body)
        } catch {
            AppLogger.error("Rule", "HTML 解析失败 len=\(body.count) err=\(error)")
            throw RuleError.noDocument
        }
        if let base = baseUrl { try? doc.setBaseUri(base) }

        // 处理反向列表（以 - 开头）与正向前缀
        var rule = ruleStr.trimmingCharacters(in: .whitespacesAndNewlines)
        var reverse = false
        if rule.hasPrefix("-") {
            reverse = true
            rule = String(rule.dropFirst()).trimmingCharacters(in: .whitespaces)
        } else if rule.hasPrefix("+") {
            rule = String(rule.dropFirst()).trimmingCharacters(in: .whitespaces)
        }

        var elements: [ElementContext]

        if rule.lowercased().hasPrefix("@xpath:") || rule.hasPrefix("//") {
            // 统一走 getXPathElements：保留节点身份（属性/文本节点也能取到值）
            let xpath = rule.lowercased().hasPrefix("@xpath:")
                ? String(rule.dropFirst(7)).trimmingCharacters(in: .whitespaces)
                : rule
            elements = try getXPathElements(xpath: xpath, body: body, baseUrl: baseUrl)
        } else {
            // class./id./tag./text./children 语法 + @tag. 级联 + !index
            let parsed = LegadoSelector.parse(rule)
            var selected: [SwiftSoup.Element]
            if parsed.selector.isEmpty {
                selected = [doc]
            } else {
                do {
                    selected = try doc.select(parsed.selector).array()
                } catch {
                    // SwiftSoup 对非法选择器会抛 Exception（如 "SwiftSoup.Exception 错误 0"）
                    AppLogger.error("Rule", "列表选择器非法 rule=\(rule.prefix(160)) selector=\(parsed.selector.prefix(160))")
                    throw RuleError.invalidRule("CSS 选择器不合法：\(parsed.selector)")
                }
            }

            for step in parsed.cascades {
                do {
                    selected = try selected.flatMap { try $0.select(step).array() }
                } catch {
                    AppLogger.error("Rule", "级联选择器非法 step=\(step.prefix(160))")
                    throw RuleError.invalidRule("CSS 选择器不合法：\(step)")
                }
            }

            // 对齐 Android AnalyzeByJSoup：支持 .N / !N / [a:b:c] / 反转
            selected = CSSParser.applyIndex(selected, parsed: parsed)
            if let ownText = parsed.ownTextFilter {
                selected = CSSParser.filterByOwnText(selected, ownText: ownText)
            }

            elements = selected.map { ElementContext(element: $0, baseUrl: baseUrl) }
        }

        if reverse { elements.reverse() }
        return elements
    }
    
    /// 从 JSON 提取元素列表
    private func getJsonElements(ruleStr: String, body: String) throws -> [ElementContext] {
        guard let data = body.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) else {
            throw RuleError.noDocument
        }

        let matched = JSONPathEvaluator.evaluate(ruleStr, root: root)
        var elements: [ElementContext] = []

        for value in matched {
            if let dict = value as? [String: Any] {
                elements.append(ElementContext(element: dict))
            } else if let array = value as? [Any] {
                for item in array {
                    if let dict = item as? [String: Any] {
                        elements.append(ElementContext(element: dict))
                    } else {
                        elements.append(ElementContext(element: ["text": JSONPathEvaluator.stringValue(item)]))
                    }
                }
            } else if let string = value as? String, !string.isEmpty {
                elements.append(ElementContext(element: ["text": string]))
            }
        }

        return elements
    }
    
    // MARK: - 在元素上下文中提取字符串
    
    /// 从单个元素中提取字符串（用于从列表项中提取书名、作者等）
    ///
    /// 所有字段规则统一走 `executeSingle`，因此 `##正则##替换`、`@css:`、`@xpath:`、
    /// `@json:`、`@js:`、`<js>`、`&&`、`||`、`%%`、`@put/@get`、`class.xxx` 语法全部生效。
    ///
    /// - Parameter joinAll: true 时把多条命中结果按行拼接（正文规则），false 时取第一条非空（书名/作者等字段）
    func getString(ruleStr: String?,
                   elementContext: ElementContext,
                   baseUrl: String? = nil,
                   joinAll: Bool = false) -> String {
        guard let ruleStr, !ruleStr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ""
        }

        let context = ExecutionContext()
        context.baseURL = (baseUrl ?? elementContext.baseUrl).flatMap { URL(string: $0) }
        context.source = elementContext.source
        context.variables = elementContext.variables
        if let initial = elementContext.initialResult {
            context.lastResult = .string(initial)
        }

        // XPath 命中的节点：字段规则只做取值时直接从节点读（对齐 Android 节点身份语义）
        if let node = elementContext.xpathNode {
            let parsed = LegadoSelector.parse(ruleStr)
            let isPureValueRule = parsed.selector.isEmpty && parsed.cascades.isEmpty && parsed.indexMode == .none
            if isPureValueRule {
                var value = XPathParser.value(from: node, attr: parsed.attr)
                if parsed.attr.lowercased() == "href" || parsed.attr.lowercased() == "src" {
                    value = CSSParser.absolute(value, base: (baseUrl ?? elementContext.baseUrl).flatMap { URL(string: $0) })
                }
                return value
            }
        }

        switch elementContext.element {
        case let dictionary as [String: Any]:
            context.jsonDict = dictionary
            context.jsonRoot = dictionary
        case let array as [Any]:
            context.jsonRoot = array
        case let element as SwiftSoup.Element:
            context.scopedElement = element
            context.htmlString = (try? element.outerHtml()) ?? ""
            if element is SwiftSoup.Document {
                context.document = element
            }
        case let html as String:
            let document = try? SwiftSoup.parse(html)
            context.document = document
            context.scopedElement = document
            context.htmlString = html
        default:
            return ""
        }

        // @put / java.put 写入的变量回传给调用方，书源变量才能跨规则生效
        defer { elementContext.variables = context.variables }

        do {
            let result = try executeSingle(rule: ruleStr, context: context)
            if joinAll { return result.text }

            let value: String
            switch result {
            case .string(let text):
                value = text
            case .list(let values):
                value = values.first(where: { !$0.isEmpty }) ?? ""
            case .none:
                value = ""
            }

            // 对齐 Android getString 的默认 unescape=true（正文走 getStringList，不做此处理）
            return value.contains("&") ? HTMLTextExtractor.decodeEntities(value) : value
        } catch {
            print("getString 错误 [\(ruleStr)]: \(error)")
            return ""
        }
    }
    
    /// 从 SwiftSoup Element 中提取字符串
    private func getStringFromElement(ruleStr: String, element: SwiftSoup.Element, baseUrl: String?) throws -> String {
        // 解析 CSS 选择器和属性
        var rule = ruleStr
        var attr = "text"
        
        // 检查 @attr 后缀
        if let atRange = rule.range(of: "@", options: .backwards) {
            let possibleAttr = String(rule[atRange.upperBound...])
            // 确保不是 CSS 选择器中的 @ 符号
            if !possibleAttr.contains(" ") && !possibleAttr.contains(".") {
                attr = possibleAttr
                rule = String(rule[..<atRange.lowerBound])
            }
        }
        
        // 空选择器直接从当前元素取
        if rule.isEmpty {
            return try extractAttr(element: element, attr: attr, baseUrl: baseUrl)
        }
        
        // 执行选择器
        guard let found = try element.select(rule).first() else {
            return ""
        }
        
        return try extractAttr(element: found, attr: attr, baseUrl: baseUrl)
    }
    
    /// 从元素提取指定属性
    private func extractAttr(element: SwiftSoup.Element, attr: String, baseUrl: String?) throws -> String {
        switch attr.lowercased() {
        case "text":
            return try element.text()
        case "textnodes":
            return element.textNodes()
                .map { $0.text().trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        case "owntext":
            return element.textNodes().map { $0.text() }.joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
        case "html":
            return CSSParser.stripScripts(try element.outerHtml())
        case "innerhtml":
            return try element.html()
        case "outerhtml":
            return try element.outerHtml()
        case "href":
            let href = try element.attr("href")
            return resolveUrl(href, baseUrl: baseUrl)
        case "src":
            let src = try element.attr("src")
            return resolveUrl(src, baseUrl: baseUrl)
        case "abs:href":
            return try element.attr("abs:href")
        case "abs:src":
            return try element.attr("abs:src")
        default:
            return try element.attr(attr)
        }
    }
    
    /// 从 JSON 字典中提取字符串
    private func getStringFromJson(ruleStr: String, json: [String: Any]) -> String {
        let path = ruleStr.replacingOccurrences(of: "$.", with: "")
        let keys = path.split(separator: ".").map { String($0) }
        
        var current: Any? = json
        for key in keys {
            if let dict = current as? [String: Any] {
                current = dict[key]
            } else {
                return ""
            }
        }
        
        if let str = current as? String { return str }
        if let num = current as? NSNumber { return num.stringValue }
        return ""
    }
    
    /// 解析相对 URL
    private func resolveUrl(_ url: String, baseUrl: String?) -> String {
        if url.hasPrefix("http") { return url }
        guard let base = baseUrl, let baseURL = URL(string: base) else { return url }
        return URL(string: url, relativeTo: baseURL)?.absoluteString ?? url
    }
    
    /// 单个节点（Android getElement）：取第一个命中节点
    func getElement(ruleStr: String?, body: String, baseUrl: String?) throws -> ElementContext? {
        guard let ruleStr, !ruleStr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return try getElements(ruleStr: ruleStr, body: body, baseUrl: baseUrl).first
    }

    // MARK: - 获取字符串列表
    
    /// 获取字符串列表（用于目录列表等）
    func getStringList(
        ruleStr: String?,
        body: String,
        baseUrl: String?,
        isUrl: Bool = false
    ) throws -> [String] {
        guard let ruleStr = ruleStr, !ruleStr.isEmpty else { return [] }
        
        let context = ExecutionContext()
        let isJson = body.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") ||
                     body.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("[")
        
        if isJson {
            context.jsonString = body
        } else {
            do {
                context.document = try SwiftSoup.parse(body)
            } catch {
                AppLogger.error("Rule", "HTML 解析失败 len=\(body.count) err=\(error)")
                throw RuleError.noDocument
            }
        }
        context.baseURL = baseUrl.flatMap { URL(string: $0) }

        let result = try executeSingle(rule: ruleStr, context: context)

        var values: [String]
        switch result {
        case .list(let list):
            values = list
        case .string(let text):
            // 对齐 Android：非列表结果按 \n 拆分
            values = text.components(separatedBy: "\n").filter { !$0.isEmpty }
        case .none:
            values = []
        }

        if isUrl {
            values = values.map { CSSParser.absolute($0, base: context.baseURL) }
        }

        // 去重并保序（Android getStringList 的 isUrl 分支行为）
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}

// MARK: - CSS 解析器 (SwiftSoup)
class CSSParser: RuleExecutor {
    var kind: RuleKind { .css }
    
    func canExecute(_ rule: String) -> Bool {
        return !rule.hasPrefix("//") && !rule.hasPrefix("$.") && !rule.hasPrefix("{{")
    }
    
    func execute(_ rule: String, context: ExecutionContext) throws -> RuleResult {
        // 有作用域元素时在当前列表项内查找，否则在整篇文档内查找
        var root = context.scopedElement ?? (context.document as? SwiftSoup.Element)

        // 只给了 HTML 字符串时补一个文档
        if root == nil, let html = context.htmlString, !html.isEmpty {
            root = try? SwiftSoup.parse(html)
        }

        guard let root else {
            throw RuleError.noDocument
        }

        let parsed = LegadoSelector.parse(rule)

        var elements: [SwiftSoup.Element]

        if let ownText = parsed.ownTextFilter {
            // text.xxx：在子孙里按「自有文本包含」筛选
            let candidates = ((try? root.getAllElements().array()) ?? []).filter { $0 !== root }
            elements = CSSParser.filterByOwnText(candidates, ownText: ownText)
        } else if parsed.selector.isEmpty {
            // 对齐 Android AnalyzeByJSoup：前置规则为空时直接取 children
            elements = (try? root.children().array()) ?? []
        } else {
            do {
                elements = try root.select(parsed.selector).array()
            } catch {
                // 正文/字段规则里的非法选择器：转成可读错误，避免把 SwiftSoup 的英文异常抛给用户
                AppLogger.error("Rule", "选择器非法 rule=\(rule.prefix(160)) selector=\(parsed.selector.prefix(160))")
                throw RuleError.invalidRule("CSS 选择器不合法：\(parsed.selector)")
            }
        }

        for step in parsed.cascades {
            do {
                elements = try elements.flatMap { try $0.select(step).array() }
            } catch {
                throw RuleError.invalidRule("CSS 选择器不合法：\(step)")
            }
        }

        elements = CSSParser.applyIndex(elements, parsed: parsed)

        guard !elements.isEmpty else { return .none }

        let loweredAttr = parsed.attr.lowercased()

        // 对齐 Android AnalyzeByJSoup：@html 对「整个元素集合」删 script/style 后取 outerHtml，只产一条
        if loweredAttr == "html" || loweredAttr == "all" {
            let combined = elements.compactMap { try? $0.outerHtml() }.joined()
            let cleaned = CSSParser.stripScripts(combined)
            return cleaned.isEmpty ? .none : .string(cleaned)
        }

        var values: [String] = []
        for element in elements {
            let value = try CSSParser.string(from: element, attr: parsed.attr, base: context.baseURL)
            if !value.isEmpty { values.append(value) }
        }

        // Android：属性类结果去重并保序（text / ownText 不去重）
        if loweredAttr != "text", loweredAttr != "textnodes", loweredAttr != "owntext" {
            var seen = Set<String>()
            values = values.filter { seen.insert($0).inserted }
        }

        guard !values.isEmpty else { return .none }
        return values.count == 1 ? .string(values[0]) : .list(values)
    }

    /// 应用 Legado 索引语法（对齐 AnalyzeByJSoup.getResultList）
    /// 支持 `.N`（选择）、`!N`（排除）、`[start:end:step]`、负数倒数、反转、越界裁剪
    static func applyIndex(_ input: [SwiftSoup.Element], parsed: LegadoSelector.Parsed) -> [SwiftSoup.Element] {
        var elements = parsed.reverse ? Array(input.reversed()) : input
        guard !elements.isEmpty, parsed.indexMode != .none else { return elements }

        let len = elements.count
        var ordered: [Int] = []

        func add(_ value: Int) {
            guard value >= 0, value < len else { return }
            if !ordered.contains(value) { ordered.append(value) }
        }

        for value in parsed.indexValues {
            if value >= 0, value < len {
                add(value)
            } else if value < 0, len >= -value {
                add(value + len)
            }
        }

        for slice in parsed.slices {
            var start = slice.start ?? 0
            if start < 0 { start += len }
            var end = slice.end ?? (len - 1)
            if end < 0 { end += len }

            if (start < 0 && end < 0) || (start >= len && end >= len) { continue }

            if start >= len { start = len - 1 } else if start < 0 { start = 0 }
            if end >= len { end = len - 1 } else if end < 0 { end = 0 }

            let rawStep = slice.step ?? 1
            if start == end || abs(rawStep) >= len {
                add(start)
                continue
            }

            var step = rawStep
            if step <= 0 {
                step = (-step < len) ? step + len : 1
            }
            guard step != 0 else { continue }

            if end > start {
                var i = start
                while i <= end {
                    add(i)
                    i += step
                }
            } else {
                var i = start
                while i >= end {
                    add(i)
                    i -= abs(step)
                }
            }
        }

        switch parsed.indexMode {
        case .exclude:
            let excluded = Set(ordered)
            elements = elements.enumerated()
                .filter { !excluded.contains($0.offset) }
                .map { $0.element }
        case .select:
            let snapshot = elements
            elements = ordered.compactMap { (0..<snapshot.count).contains($0) ? snapshot[$0] : nil }
        case .none:
            break
        }

        return elements
    }

    /// text.xxx：按「自有文本包含」筛选（对齐 Android getElementsContainingOwnText）
    static func filterByOwnText(_ elements: [SwiftSoup.Element], ownText: String) -> [SwiftSoup.Element] {
        guard !ownText.isEmpty else { return elements }
        let target = ownText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return elements }

        return elements.filter { element in
            element.textNodes().contains { $0.text().contains(target) }
        }
    }

    /// 从元素中按属性名取值
    static func string(from element: SwiftSoup.Element, attr: String, base: URL?) throws -> String {
        switch attr.lowercased() {
        case "text":
            let html = (try? element.html()) ?? ""
            if html.contains("<") {
                let text = HTMLTextExtractor.plainText(from: html)
                if !text.isEmpty { return text }
            }
            return try element.text()

        case "textnodes":
            return element.textNodes()
                .map { $0.text().trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")

        case "owntext":
            return element.textNodes().map { $0.text() }.joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)

        case "html":
            // 对齐 Android AnalyzeByJSoup：@html = 删除 script/style 后的 outerHtml
            return CSSParser.stripScripts(try element.outerHtml())

        case "innerhtml":
            return try element.html()

        case "outerhtml", "all":
            return try element.outerHtml()

        case "href", "abs:href":
            return CSSParser.absolute(try element.attr("href"), base: base)

        case "src", "abs:src":
            // 很多站的封面是懒加载：真实地址在 data-src / data-original 里，src 是占位图
            var raw = try element.attr("src")
            for fallback in ["data-src", "data-original", "data-lazy-src", "data-echo"] where raw.isEmpty {
                raw = try element.attr(fallback)
            }
            return CSSParser.absolute(raw, base: base)

        default:
            // 对齐 Android：属性不存在就是空结果，不回退正文
            // （否则 data-src 取不到时会把整段文字当封面地址）
            let raw = try element.attr(attr)
            return raw.isEmpty ? "" : CSSParser.absoluteIfNeeded(raw, attr: attr.lowercased(), base: base)
        }
    }

    /// 去掉 script/style（Android 的 @html 会先剔除这两类节点）
    static func stripScripts(_ html: String) -> String {
        var text = html
        text = text.replacingOccurrences(of: "(?is)<script[^>]*>.*?</script>", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?is)<style[^>]*>.*?</style>", with: "", options: .regularExpression)
        return text
    }

    /// 只对「看起来是链接」的属性做相对路径补全，避免把正文文本拼成 URL
    static func absoluteIfNeeded(_ value: String, attr: String, base: URL?) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let urlAttributes: Set<String> = [
            "src", "href", "url", "poster", "content",
            "data-src", "data-original", "data-lazy-src", "data-echo"
        ]

        if urlAttributes.contains(attr) || trimmed.hasPrefix("/") || trimmed.hasPrefix("http") {
            return absolute(trimmed, base: base)
        }
        return trimmed
    }

    /// 相对 URL 补全
    static func absolute(_ value: String, base: URL?) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") || trimmed.hasPrefix("data:") {
            return trimmed
        }
        guard let base else { return trimmed }
        return URL(string: trimmed, relativeTo: base)?.absoluteString ?? trimmed
    }
}

// MARK: - XPath 解析器 (Kanna)
class XPathParser: RuleExecutor {
    var kind: RuleKind { .xpath }

    /// 从保留的 Kanna 节点直接取值（text / html / 属性）
    static func value(from node: XMLElement, attr: String) -> String {
        switch attr.lowercased() {
        case "text", "owntext", "":
            return node.text ?? ""
        case "html", "innerhtml", "outerhtml", "all":
            return node.toHTML ?? ""
        default:
            return attribute(attr, html: node.toHTML)
        }
    }
    
    func canExecute(_ rule: String) -> Bool {
        return rule.hasPrefix("//")
    }
    
    func execute(_ rule: String, context: ExecutionContext) throws -> RuleResult {
        // 文档可能是 SwiftSoup.Document（不再是字符串），这里做兼容取值
        let html: String
        if let raw = context.htmlString, !raw.isEmpty {
            html = raw
        } else if let raw = context.document as? String {
            html = raw
        } else if let element = context.scopedElement {
            html = (try? element.outerHtml()) ?? ""
        } else if let element = context.document as? SwiftSoup.Element {
            html = (try? element.outerHtml()) ?? ""
        } else {
            throw RuleError.noDocument
        }

        guard !html.isEmpty else { throw RuleError.noDocument }

        let parsed = LegadoSelector.parse(rule)
        let xpath = parsed.selector.isEmpty ? rule : parsed.selector
        let attr = parsed.attr

        AppLogger.debug("Rule", "XPath 执行 xpath=\(xpath.prefix(160))")
        // 非法 XPath 交给 libxml2 有可能直接崩，这里先做括号/引号配平校验
        guard XPathParser.isSafe(xpath) else {
            AppLogger.error("Rule", "XPath 表达式不合法，已跳过：\(xpath.prefix(200))")
            throw RuleError.invalidRule("XPath 表达式不合法")
        }

        let doc = try Kanna.HTML(html: html, encoding: .utf8)

        var results: [String] = []
        for node in doc.xpath(xpath) {
            let value: String?
            switch attr.lowercased() {
            case "text":
                value = node.text
            case "html", "innerhtml", "outerhtml", "all":
                value = node.toHTML
            case "href":
                let raw = XPathParser.attribute("href", html: node.toHTML)
                value = raw.isEmpty ? nil : CSSParser.absolute(raw, base: context.baseURL)
            case "src":
                let raw = XPathParser.attribute("src", html: node.toHTML)
                value = raw.isEmpty ? nil : CSSParser.absolute(raw, base: context.baseURL)
            default:
                let raw = XPathParser.attribute(attr, html: node.toHTML)
                value = raw.isEmpty ? node.text : raw
            }

            if let value, !value.isEmpty {
                results.append(value)
            }
        }

        if results.count == 1 {
            return .string(results[0])
        } else if !results.isEmpty {
            return .list(results)
        }

        return .none
    }

    /// XPath 表达式安全校验：括号/引号配平、长度限制
    static func isSafe(_ xpath: String) -> Bool {
        let trimmed = xpath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 2000 else { return false }

        var bracketDepth = 0
        var parenDepth = 0
        var quote: Character?

        for char in trimmed {
            if let current = quote {
                if char == current { quote = nil }
                continue
            }
            switch char {
            case "'", "\"":
                quote = char
            case "[":
                bracketDepth += 1
            case "]":
                bracketDepth -= 1
                if bracketDepth < 0 { return false }
            case "(":
                parenDepth += 1
            case ")":
                parenDepth -= 1
                if parenDepth < 0 { return false }
            default:
                break
            }
        }

        return bracketDepth == 0 && parenDepth == 0 && quote == nil
    }

    /// 从节点的 outerHTML 里取属性值
    /// Kanna 各版本对 `attributes` 的暴露不一致，这里只依赖 `toHTML`，避免编译期 API 差异
    static func attribute(_ name: String, html: String?) -> String {
        guard let html, !html.isEmpty, !name.isEmpty else { return "" }

        let escaped = NSRegularExpression.escapedPattern(for: name)
        let pattern = "\\b" + escaped + "\\s*=\\s*[\"']([^\"']*)[\"']"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return ""
        }

        let range = NSRange(html.startIndex..., in: html)
        guard let match = regex.firstMatch(in: html, range: range),
              match.numberOfRanges > 1,
              let valueRange = Range(match.range(at: 1), in: html) else {
            return ""
        }

        return String(html[valueRange])
    }
}

// MARK: - JSONPath 解析器
class JSONPathParser: RuleExecutor {
    var kind: RuleKind { .jsonPath }
    
    func canExecute(_ rule: String) -> Bool {
        return rule.hasPrefix("$.")
    }
    
    func execute(_ rule: String, context: ExecutionContext) throws -> RuleResult {
        if context.jsonRoot == nil {
            if let jsonString = context.jsonString,
               let data = jsonString.data(using: .utf8) {
                context.jsonRoot = try? JSONSerialization.jsonObject(with: data)
            } else if let dict = context.jsonDict {
                context.jsonRoot = dict
            }
        }

        guard let root = context.jsonRoot else {
            throw RuleError.noDocument
        }

        let matched = JSONPathEvaluator.evaluate(rule, root: root)
        guard !matched.isEmpty else { return .none }

        var values: [String] = []
        for value in matched {
            if let array = value as? [Any] {
                for item in array {
                    let text = JSONPathEvaluator.stringValue(item)
                    if !text.isEmpty { values.append(text) }
                }
            } else {
                let text = JSONPathEvaluator.stringValue(value)
                if !text.isEmpty { values.append(text) }
            }
        }

        guard !values.isEmpty else { return .none }
        return values.count == 1 ? .string(values[0]) : .list(values)
    }
}

// MARK: - 正则解析器
class RegexParser: RuleExecutor {
    var kind: RuleKind { .regex }
    
    func canExecute(_ rule: String) -> Bool {
        return rule.hasPrefix("regex:") || rule.contains("{{regex")
    }
    
    func execute(_ rule: String, context: ExecutionContext) throws -> RuleResult {
        guard let input = context.lastResult.string ?? (context.document as? String) else {
            throw RuleError.noDocument
        }
        
        let pattern = rule.replacingOccurrences(of: "regex:", with: "")
        
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            throw RuleError.invalidRule("无效正则：\(pattern)")
        }
        
        let range = NSRange(input.startIndex..., in: input)
        var results: [String] = []
        
        for match in regex.matches(in: input, range: range) {
            if let matchRange = Range(match.range, in: input) {
                results.append(String(input[matchRange]))
            }
        }
        
        if results.count == 1 {
            return .string(results[0])
        } else if !results.isEmpty {
            return .list(results)
        }
        
        return .none
    }
}

// MARK: - JavaScript 解析器
class JavaScriptParser: RuleExecutor {
    var kind: RuleKind { .js }
    
    func canExecute(_ rule: String) -> Bool {
        let trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("@js:") || rule.contains("{{js") || rule.contains("<js>")
    }
    
    func execute(_ rule: String, context: ExecutionContext) throws -> RuleResult {
        let jsCode = extractJS(rule)

        // 引擎初始化失败时不再崩溃，交给调用方按「该源解析失败」处理
        guard let jsContext = context.jsContext else {
            throw RuleError.executionFailed("JavaScript 引擎初始化失败（内存不足或被系统限制）")
        }

        jsContext.setObject(context.lastResult.string ?? "", forKeyedSubscript: "result" as NSString)
        jsContext.setObject(context.baseURL?.absoluteString ?? "", forKeyedSubscript: "baseUrl" as NSString)

        let jsValue = jsContext.evaluateScript(jsCode)
        
        if let string = jsValue?.toString() {
            return .string(string)
        }
        
        return .none
    }
    
    private func extractJS(_ rule: String) -> String {
        // Legado 的 @js: 前缀：后面整段就是 JS 代码，不能把 "@js:" 一起丢给 JSC
        let trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("@js:") {
            return String(trimmed.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let patterns = [
            #"{{js(.*?)}}"#,
            #"<js>(.*?)</js>"#
        ]
        
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(
                in: rule,
                range: NSRange(rule.startIndex..., in: rule)
               ),
               let range = Range(match.range(at: 1), in: rule) {
                return String(rule[range]).trimmingCharacters(in: .whitespaces)
            }
        }
        
        return rule
    }
}

// MARK: - 错误类型
enum RuleError: LocalizedError {
    case noDocument
    case invalidRule(String)
    case unsupportedRule(String)
    case executionFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .noDocument: return "缺少文档"
        case .invalidRule(let rule): return "无效规则：\(rule)"
        case .unsupportedRule(let rule): return "不支持的规则：\(rule)"
        case .executionFailed(let error): return "执行失败：\(error)"
        }
    }
}
