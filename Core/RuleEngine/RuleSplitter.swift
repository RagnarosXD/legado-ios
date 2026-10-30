import Foundation
import CoreFoundation

struct SplitRule {
    let type: RuleKind
    let rule: String
    let replace: (pattern: String, replacement: String, group: Int?)?
}

enum RuleOperator {
    case and
    case or
    case format
    case replace
}

class RuleSplitter {
    static func split(_ ruleString: String) -> [SplitRule] {
        let trimmed = ruleString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let operators = parseOperators(trimmed)
        let segments: [String]

        if let orSegments = operators.first(where: { $0.operator == .or })?.segments {
            segments = orSegments
        } else if let andSegments = operators.first(where: { $0.operator == .and })?.segments {
            segments = andSegments
        } else {
            segments = [trimmed]
        }

        return segments.compactMap { parseSegment($0) }
    }

    static func parseOperators(_ ruleString: String) -> [(operator: RuleOperator, segments: [String])] {
        let trimmed = ruleString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var parsed: [(operator: RuleOperator, segments: [String])] = []

        if let segments = splitIfContains(trimmed, token: "&&") {
            parsed.append((.and, segments))
        }
        if let segments = splitIfContains(trimmed, token: "||") {
            parsed.append((.or, segments))
        }
        if let segments = splitIfContains(trimmed, token: "%%") {
            parsed.append((.format, segments))
        }
        if let segments = splitIfContains(trimmed, token: "##") {
            parsed.append((.replace, segments))
        }

        return parsed
    }

    private static func parseSegment(_ segment: String) -> SplitRule? {
        let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let (rulePart, replacePart) = parseReplace(trimmed)
        let (type, rule) = parseTypeAndRule(rulePart)

        return SplitRule(type: type, rule: rule, replace: replacePart)
    }

    private static func parseTypeAndRule(_ rawRule: String) -> (RuleKind, String) {
        let trimmed = rawRule.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = trimmed.lowercased()

        let prefixedKinds: [(prefix: String, kind: RuleKind)] = [
            ("@css:", .css),
            ("@xpath:", .xpath),
            ("@json:", .jsonPath),
            ("@js:", .js),
            ("@regex:", .regex)
        ]

        for item in prefixedKinds where lowercased.hasPrefix(item.prefix) {
            let content = String(trimmed.dropFirst(item.prefix.count))
            return (item.kind, content)
        }

        if trimmed.hasPrefix("//") {
            return (.xpath, trimmed)
        }
        if trimmed.hasPrefix("$.") {
            return (.jsonPath, trimmed)
        }
        if lowercased.hasPrefix("regex:") || lowercased.contains("{{regex") {
            return (.regex, trimmed)
        }
        if lowercased.contains("{{js") || lowercased.contains("<js>") {
            return (.js, trimmed)
        }

        return (.css, trimmed)
    }

    private static func parseReplace(_ rule: String) -> (
        rule: String,
        replace: (pattern: String, replacement: String, group: Int?)?
    ) {
        let parts = rule.components(separatedBy: "##")
        guard parts.count >= 3 else {
            return (rule, nil)
        }

        let targetRule = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = parts[1]
        let payload = Array(parts.dropFirst(2))

        if payload.count == 1 {
            let token = payload[0]
            if let group = Int(token) {
                return (targetRule, (pattern: pattern, replacement: "$\(group)", group: group))
            }
            return (targetRule, (pattern: pattern, replacement: token, group: nil))
        }

        if let last = payload.last, let group = Int(last) {
            let replacementParts = payload.dropLast()
            let replacement = replacementParts.joined(separator: "##")
            let resolvedReplacement = replacement.isEmpty ? "$\(group)" : replacement
            return (targetRule, (pattern: pattern, replacement: resolvedReplacement, group: group))
        }

        return (targetRule, (pattern: pattern, replacement: payload.joined(separator: "##"), group: nil))
    }

    private static func splitIfContains(_ input: String, token: String) -> [String]? {
        guard input.contains(token) else { return nil }
        let segments = input
            .components(separatedBy: token)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return segments.isEmpty ? nil : segments
    }
}

// MARK: - Legado 默认语法（class./id./tag./text./children、@attr、!index、@tag. 级联）

/// 把 Legado 书源的默认语法解析成 SwiftSoup 可用的 CSS 选择器 + 属性 + 索引。
///
/// 支持：
///   - `class.name` / `id.name` / `tag.a` / `text.a` / `children`
///   - `@text` / `@html` / `@href` / `@src` / `@abs:href` / `@任意属性`
///   - `!0` / `!-1` 索引（负数为倒数）
///   - `div#list@tag.li` 这类「先定位容器、再取子项」的级联写法
enum LegadoSelector {

    struct Parsed {
        var selector: String = ""
        /// 级联步骤：从外到内依次 select（对应 @tag. / @class. 语法）
        var cascades: [String] = []
        var attr: String = "text"
        var index: Int?
    }

    static func parse(_ rule: String) -> Parsed {
        var text = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        var parsed = Parsed()
        guard !text.isEmpty else { return parsed }

        // 末尾索引：class.item!0
        if let bang = text.lastIndex(of: "!") {
            let tail = String(text[text.index(after: bang)...]).trimmingCharacters(in: .whitespaces)
            if !tail.isEmpty, let idx = Int(tail) {
                parsed.index = idx
                text = String(text[..<bang]).trimmingCharacters(in: .whitespaces)
            }
        }

        // 从右往左剥离 @ 段：@href 是属性，@tag.li / @class.x 是级联步骤
        var attrResolved = false
        while let at = text.lastIndex(of: "@") {
            let tail = String(text[text.index(after: at)...]).trimmingCharacters(in: .whitespaces)
            let head = String(text[..<at]).trimmingCharacters(in: .whitespaces)

            if !attrResolved, isAttribute(tail) {
                parsed.attr = normalizeAttribute(tail)
                attrResolved = true
                text = head
                continue
            }

            if isStepPrefix(tail) {
                parsed.cascades.insert(convert(tail), at: 0)
                text = head
                continue
            }

            break
        }

        // 索引也可能写在级联之前：class.book!1@tag.h2
        if let bang = text.lastIndex(of: "!") {
            let tail = String(text[text.index(after: bang)...]).trimmingCharacters(in: .whitespaces)
            if !tail.isEmpty, let idx = Int(tail) {
                parsed.index = idx
                text = String(text[..<bang]).trimmingCharacters(in: .whitespaces)
            }
        }

        parsed.selector = convert(text)
        return parsed
    }

    /// 判断是否是 Legado 的「步骤前缀」，如 @tag.li
    static func isStepPrefix(_ value: String) -> Bool {
        if value == "children" { return true }
        for prefix in ["tag.", "class.", "id.", "text."] where value.hasPrefix(prefix) {
            return true
        }
        return false
    }

    /// 判断 @ 之后是否是属性名（只允许字母、数字、冒号、下划线、减号）
    static func isAttribute(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ":-_"))
        for scalar in value.unicodeScalars where !allowed.contains(scalar) {
            return false
        }
        return true
    }

    /// 属性名归一化（textNodes -> textnodes 由使用方处理，这里只做去空格）
    static func normalizeAttribute(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 默认语法 → CSS 选择器
    static func convert(_ rule: String) -> String {
        let trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        if trimmed == "children" { return "> *" }
        if trimmed.hasPrefix("@css:") {
            return String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        }
        if trimmed.hasPrefix("class.") {
            return "." + String(trimmed.dropFirst(6)).trimmingCharacters(in: .whitespaces)
        }
        if trimmed.hasPrefix("id.") {
            return "#" + String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        }
        if trimmed.hasPrefix("tag.") {
            return String(trimmed.dropFirst(4)).trimmingCharacters(in: .whitespaces)
        }
        if trimmed.hasPrefix("text.") {
            return String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        }
        return trimmed
    }
}

// MARK: - JSONPath（支持 $..key、[*]、[?(@.k=='v')]、[0:2]）

enum JSONPathEvaluator {

    private enum Token {
        case key(String)
        case recursive(String?)
        case index(Int)
        case wildcard
        case slice(Int?, Int?)
        case filter(String)
    }

    /// 返回所有命中的节点
    static func evaluate(_ path: String, root: Any) -> [Any] {
        var text = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("@json:") {
            text = String(text.dropFirst(6)).trimmingCharacters(in: .whitespaces)
        }
        if text.hasPrefix("$") {
            text.removeFirst()
        }
        guard !text.isEmpty else { return [root] }
        return evaluateTokens(tokenize(text), root: root)
    }

    /// 把任意 JSON 值转成字符串（Bool 需要特殊处理，否则 NSNumber 会输出 1/0）
    static func stringValue(_ value: Any) -> String {
        if let string = value as? String { return string }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            }
            return number.stringValue
        }
        if value is NSNull { return "" }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return String(describing: value)
    }

    // MARK: - 词法

    private static func tokenize(_ path: String) -> [Token] {
        var tokens: [Token] = []
        var index = path.startIndex

        while index < path.endIndex {
            let char = path[index]

            if char == "." {
                var cursor = path.index(after: index)
                var recursive = false
                if cursor < path.endIndex, path[cursor] == "." {
                    recursive = true
                    cursor = path.index(after: cursor)
                }

                var key = ""
                while cursor < path.endIndex, path[cursor] != ".", path[cursor] != "[" {
                    key.append(path[cursor])
                    cursor = path.index(after: cursor)
                }

                if recursive {
                    tokens.append(.recursive(key.isEmpty ? nil : key))
                } else if !key.isEmpty {
                    tokens.append(.key(key))
                }
                index = cursor
                continue
            }

            if char == "[" {
                guard let close = path[index...].firstIndex(of: "]") else { break }
                let inner = String(path[path.index(after: index)..<close])
                    .trimmingCharacters(in: .whitespaces)
                tokens.append(parseBracket(inner))
                index = path.index(after: close)
                continue
            }

            var key = ""
            var cursor = index
            while cursor < path.endIndex, path[cursor] != ".", path[cursor] != "[" {
                key.append(path[cursor])
                cursor = path.index(after: cursor)
            }
            if !key.isEmpty { tokens.append(.key(key)) }
            index = cursor
        }

        return tokens
    }

    private static func parseBracket(_ inner: String) -> Token {
        if inner == "*" { return .wildcard }
        if inner.hasPrefix("?") { return .filter(inner) }

        if inner.contains(":") {
            let parts = inner
                .split(separator: ":", omittingEmptySubsequences: false)
                .map { String($0).trimmingCharacters(in: .whitespaces) }
            let start = parts.indices.contains(0) ? Int(parts[0]) : nil
            let end = parts.indices.contains(1) ? Int(parts[1]) : nil
            return .slice(start, end)
        }

        if let number = Int(inner) { return .index(number) }

        var key = inner
        if (key.hasPrefix("'") && key.hasSuffix("'")) || (key.hasPrefix("\"") && key.hasSuffix("\"")) {
            key = String(key.dropFirst().dropLast())
        }
        return .key(key)
    }

    // MARK: - 求值

    private static func evaluateTokens(_ tokens: [Token], root: Any) -> [Any] {
        var current: [Any] = [root]

        for token in tokens {
            var next: [Any] = []

            for value in current {
                switch token {
                case .key(let key):
                    if let dict = value as? [String: Any] {
                        if let child = dict[key] { next.append(child) }
                    } else if let array = value as? [Any] {
                        if let idx = Int(key) {
                            if idx >= 0, idx < array.count { next.append(array[idx]) }
                        } else {
                            for item in array {
                                if let dict = item as? [String: Any], let child = dict[key] {
                                    next.append(child)
                                }
                            }
                        }
                    }

                case .recursive(let key):
                    collectRecursive(value, key: key, into: &next)

                case .index(let idx):
                    if let array = value as? [Any] {
                        let real = idx < 0 ? array.count + idx : idx
                        if real >= 0, real < array.count { next.append(array[real]) }
                    }

                case .wildcard:
                    if let array = value as? [Any] {
                        next.append(contentsOf: array)
                    } else if let dict = value as? [String: Any] {
                        next.append(contentsOf: dict.values)
                    }

                case .slice(let start, let end):
                    if let array = value as? [Any] {
                        let lower = max(0, start ?? 0)
                        let upper = min(array.count, end ?? array.count)
                        if lower < upper { next.append(contentsOf: array[lower..<upper]) }
                    }

                case .filter(let expr):
                    if let array = value as? [Any] {
                        next.append(contentsOf: array.filter { matches(filter: expr, item: $0) })
                    }
                }
            }

            current = next
            if current.isEmpty { break }
        }

        return current
    }

    private static func collectRecursive(
        _ value: Any,
        key: String?,
        into result: inout [Any],
        depth: Int = 0
    ) {
        // 深度上限：畸形/超深 JSON 用 $.. 递归会把栈打爆
        guard depth < 64 else { return }

        if let dict = value as? [String: Any] {
            for (name, child) in dict {
                if key == nil || name == key { result.append(child) }
                collectRecursive(child, key: key, into: &result, depth: depth + 1)
            }
        } else if let array = value as? [Any] {
            for item in array {
                collectRecursive(item, key: key, into: &result, depth: depth + 1)
            }
        }
    }

    // MARK: - 过滤器

    private static func matches(filter: String, item: Any) -> Bool {
        var expr = filter.trimmingCharacters(in: .whitespaces)
        if expr.hasPrefix("?") { expr = String(expr.dropFirst()) }
        expr = expr.trimmingCharacters(in: .whitespaces)
        if expr.hasPrefix("("), expr.hasSuffix(")") {
            expr = String(expr.dropFirst().dropLast())
        }
        expr = expr.trimmingCharacters(in: .whitespaces)

        for op in ["==", "!=", ">=", "<=", ">", "<"] {
            guard let range = expr.range(of: op) else { continue }

            let lhs = String(expr[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            let rhs = String(expr[range.upperBound...]).trimmingCharacters(in: .whitespaces)

            guard let leftValue = resolveOperand(lhs, item: item) else { return false }
            let leftText = stringValue(leftValue)
            let rightText = unquote(rhs)

            switch op {
            case "==": return leftText == rightText
            case "!=": return leftText != rightText
            default:
                guard let left = Double(leftText), let right = Double(rightText) else { return false }
                if op == ">" { return left > right }
                if op == "<" { return left < right }
                if op == ">=" { return left >= right }
                return left <= right
            }
        }

        return resolveOperand(expr, item: item) != nil
    }

    private static func resolveOperand(_ text: String, item: Any) -> Any? {
        var path = text.trimmingCharacters(in: .whitespaces)
        if path.hasPrefix("@") { path = String(path.dropFirst()) }
        if path.hasPrefix(".") { path = String(path.dropFirst()) }
        if path.isEmpty { return item }
        if path.hasPrefix("'") || path.hasPrefix("\"") { return unquote(path) }

        var current: Any? = item
        for part in path.split(separator: ".") {
            let key = String(part)
            if let dict = current as? [String: Any] {
                current = dict[key]
            } else if let array = current as? [Any], let idx = Int(key), idx >= 0, idx < array.count {
                current = array[idx]
            } else {
                return nil
            }
        }
        return current
    }

    private static func unquote(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespaces)
        if value.count >= 2,
           (value.hasPrefix("'") && value.hasSuffix("'")) || (value.hasPrefix("\"") && value.hasSuffix("\"")) {
            value = String(value.dropFirst().dropLast())
        }
        return value
    }
}

// MARK: - HTML → 纯文本（保留段落换行）

enum HTMLTextExtractor {

    static func plainText(from html: String) -> String {
        var text = html

        text = text.replacingOccurrences(of: "(?is)<(script|style)[^>]*>.*?</\\1>",
                                         with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?i)<br\\s*/?>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?i)</(p|div|h[1-6]|li|tr|section|article)\\s*>",
                                         with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        text = decodeEntities(text)
        text = text.replacingOccurrences(of: "[\t\u{00A0} ]+", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: " *\n *", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func decodeEntities(_ text: String) -> String {
        var result = text
        let map = ["&nbsp;": " ", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
                   "&apos;": "'", "&#39;": "'", "&amp;": "&", "&ldquo;": "“",
                   "&rdquo;": "”", "&hellip;": "…", "&mdash;": "—", "&middot;": "·"]
        for (key, value) in map {
            result = result.replacingOccurrences(of: key, with: value)
        }

        guard let regex = try? NSRegularExpression(pattern: "&#(x?[0-9a-fA-F]+);") else {
            return result
        }

        let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
        for match in matches.reversed() {
            let nsText = result as NSString
            guard match.numberOfRanges > 1 else { continue }
            let raw = nsText.substring(with: match.range(at: 1))
            let value = raw.lowercased().hasPrefix("x")
                ? UInt32(raw.dropFirst(), radix: 16)
                : UInt32(raw)
            if let value, let scalar = Unicode.Scalar(value) {
                result = nsText.replacingCharacters(in: match.range, with: String(Character(scalar)))
            }
        }

        return result
    }
}
