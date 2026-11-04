import Foundation
import CoreFoundation

struct SplitRule {
    let type: RuleKind
    let rule: String
    let replace: (pattern: String, replacement: String, group: Int?, replaceFirst: Bool)?
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

        // 对齐 Android AnalyzeRule.SourceRule：
        // "@@" 是转义前缀，后续内容按默认（CSS/默认选择器）解析
        if trimmed.hasPrefix("@@") {
            return (.css, String(trimmed.dropFirst(2)))
        }

        // 以 "/" 开头一律视为 XPath（Android 里 /html/body/... 也走 XPath，不只是 //）
        if trimmed.hasPrefix("/") {
            return (.xpath, trimmed)
        }
        // 以 "$." 或 "$[" 开头都视为 JSONPath
        if trimmed.hasPrefix("$.") || trimmed.hasPrefix("$[") {
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

    // MARK: - 组合符切分（对齐 Android RuleAnalyzer.splitRule）

    enum Combination {
        case single
        case or
        case and
        case cross
    }

    /// Android 语义：分隔符种类由「最先出现的那一个」决定；
    /// `[...]`、`(...)`、引号内的分隔符不参与切分（避免 JSONPath 过滤器里的 && / || 被切坏）
    static func splitCombination(_ rule: String) -> (kind: Combination, parts: [String]) {
        guard let separator = firstTopLevelSeparator(in: rule) else {
            return (.single, [rule])
        }

        let parts = splitTopLevel(rule, separator: separator)
        guard parts.count > 1 else { return (.single, [rule]) }

        switch separator {
        case "||": return (.or, parts)
        case "&&": return (.and, parts)
        default: return (.cross, parts)
        }
    }

    private static func firstTopLevelSeparator(in rule: String) -> String? {
        let candidates = ["&&", "||", "%%"]
        var squareDepth = 0
        var parenDepth = 0
        var quote: Character?
        var index = rule.startIndex

        while index < rule.endIndex {
            let char = rule[index]

            if let active = quote {
                if char == active { quote = nil }
                index = rule.index(after: index)
                continue
            }

            switch char {
            case "'", "\"":
                quote = char
            case "[":
                squareDepth += 1
            case "]":
                squareDepth = max(0, squareDepth - 1)
            case "(":
                parenDepth += 1
            case ")":
                parenDepth = max(0, parenDepth - 1)
            default:
                break
            }

            if squareDepth == 0, parenDepth == 0, quote == nil {
                for candidate in candidates where rule[index...].hasPrefix(candidate) {
                    return candidate
                }
            }

            index = rule.index(after: index)
        }

        return nil
    }

    static func splitTopLevel(_ rule: String, separator: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var squareDepth = 0
        var parenDepth = 0
        var quote: Character?
        var index = rule.startIndex

        while index < rule.endIndex {
            let char = rule[index]

            if let active = quote {
                if char == active { quote = nil }
                current.append(char)
                index = rule.index(after: index)
                continue
            }

            if char == "'" || char == "\"" {
                quote = char
                current.append(char)
                index = rule.index(after: index)
                continue
            }

            if char == "[" { squareDepth += 1 }
            if char == "]" { squareDepth = max(0, squareDepth - 1) }
            if char == "(" { parenDepth += 1 }
            if char == ")" { parenDepth = max(0, parenDepth - 1) }

            if squareDepth == 0, parenDepth == 0, rule[index...].hasPrefix(separator) {
                parts.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current = ""
                index = rule.index(index, offsetBy: separator.count)
                continue
            }

            current.append(char)
            index = rule.index(after: index)
        }

        parts.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
        return parts.filter { !$0.isEmpty }
    }

    // MARK: - JS 分段（对齐 Android splitSourceRule）

    struct JSSegment {
        var isJS: Bool
        var text: String
    }

    /// 按 `<js>...</js>` / `@js:...` 把规则切成「普通段 / JS 段」，
    /// 普通段在上一段结果上继续解析，JS 段执行脚本（Android AnalyzeRule.kt:593-636）
    static func splitByJSSegments(_ rule: String) -> [JSSegment] {
        let lowered = rule.lowercased()
        guard lowered.contains("<js>") || lowered.contains("@js:") else {
            return [JSSegment(isJS: false, text: rule)]
        }

        guard let regex = try? NSRegularExpression(
            pattern: #"(?is)<js>([\w\W]*?)</js>|@js:([\w\W]*)"#
        ) else {
            return [JSSegment(isJS: false, text: rule)]
        }

        let ns = rule as NSString
        let matches = regex.matches(in: rule, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return [JSSegment(isJS: false, text: rule)] }

        var segments: [JSSegment] = []
        var cursor = rule.startIndex

        for match in matches {
            guard let fullRange = Range(match.range, in: rule) else { continue }

            if fullRange.lowerBound > cursor {
                let text = String(rule[cursor..<fullRange.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    segments.append(JSSegment(isJS: false, text: text))
                }
            }

            var body = ""
            if match.range(at: 2).location != NSNotFound, let r = Range(match.range(at: 2), in: rule) {
                body = String(rule[r])
            } else if match.range(at: 1).location != NSNotFound, let r = Range(match.range(at: 1), in: rule) {
                body = String(rule[r])
            }

            segments.append(JSSegment(
                isJS: true,
                text: body.trimmingCharacters(in: .whitespacesAndNewlines)
            ))
            cursor = fullRange.upperBound
        }

        if cursor < rule.endIndex {
            let text = String(rule[cursor...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                segments.append(JSSegment(isJS: false, text: text))
            }
        }

        return segments.isEmpty ? [JSSegment(isJS: false, text: rule)] : segments
    }

    private static func parseReplace(_ rule: String) -> (
        rule: String,
        replace: (pattern: String, replacement: String, group: Int?, replaceFirst: Bool)?
    ) {
        // Android AnalyzeRule.kt:549：###pattern##replacement 表示「只替换第一个匹配」
        var working = rule
        var replaceFirst = false
        if let range = working.range(of: "###") {
            replaceFirst = true
            working = working.replacingCharacters(in: range, with: "##")
        }

        let parts = working.components(separatedBy: "##")
        guard parts.count >= 3 else {
            return (rule, nil)
        }

        let targetRule = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = parts[1]
        let payload = Array(parts.dropFirst(2))

        if payload.count == 1 {
            let token = payload[0]
            if let group = Int(token) {
                return (targetRule, (pattern: pattern, replacement: "$\(group)", group: group, replaceFirst: replaceFirst))
            }
            return (targetRule, (pattern: pattern, replacement: token, group: nil, replaceFirst: replaceFirst))
        }

        if let last = payload.last, let group = Int(last) {
            let replacementParts = payload.dropLast()
            let replacement = replacementParts.joined(separator: "##")
            let resolvedReplacement = replacement.isEmpty ? "$\(group)" : replacement
            return (targetRule, (pattern: pattern, replacement: resolvedReplacement, group: group, replaceFirst: replaceFirst))
        }

        return (targetRule, (pattern: pattern, replacement: payload.joined(separator: "##"), group: nil, replaceFirst: replaceFirst))
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

    /// `[start:end:step]` 区间（对齐 Android AnalyzeByJSoup.findIndexSet 的 Triple）
    struct Slice {
        var start: Int?
        var end: Int?
        var step: Int?
    }

    enum IndexMode {
        case none
        /// `.` 前缀：选择
        case select
        /// `!` 前缀：排除
        case exclude
    }

    struct Parsed {
        var selector: String = ""
        /// 级联步骤：从外到内依次 select（对应 @tag. / @class. 语法）
        var cascades: [String] = []
        var attr: String = "text"
        /// `text.xxx`：按「自有文本包含」筛选（Android getElementsContainingOwnText）
        var ownTextFilter: String?
        /// 规则首字符 `-`：整个列表反转
        var reverse: Bool = false
        var indexMode: IndexMode = .none
        /// 单位置索引（`.` / `!` 写法），支持负数（倒序）
        var indexValues: [Int] = []
        /// `[...]` 区间写法
        var slices: [Slice] = []
    }

    static func parse(_ rule: String) -> Parsed {
        var text = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        var parsed = Parsed()
        guard !text.isEmpty else { return parsed }

        // 规则首字符 - / +：反转 / 正序（Android BookList.kt:90-96）
        if text.hasPrefix("-") {
            parsed.reverse = true
            text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
        } else if text.hasPrefix("+") {
            text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
        }

        // 1) 从右往左剥离 @ 段：@href 是属性，@tag.li / @class.x 是级联步骤
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

            // 普通 CSS 级联（Android 把 @ 切成多段，前 n-1 段是选择器）：
            // 例如 div.a@div.item@text 中的 div.item
            if looksLikeSelector(tail) {
                parsed.cascades.insert(convert(tail), at: 0)
                text = head
                continue
            }

            break
        }

        // 2) 尾部索引：`[a:b:c]` 区间 或 `.N` / `!N` 列表
        parseTrailingIndex(&text, into: &parsed)

        // 3) text.xxx → 自有文本包含匹配
        if text.hasPrefix("text.") {
            parsed.ownTextFilter = String(text.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            text = ""
        }

        parsed.selector = convert(text)
        return parsed
    }

    // MARK: - 尾部索引解析（对齐 findIndexSet）

    private static func parseTrailingIndex(_ text: inout String, into parsed: inout Parsed) {
        let source = text.trimmingCharacters(in: .whitespaces)

        // A. `[...]`：支持 `[0]`、`[-1]`、`[0:2]`、`[0:2:1]`、`[-1:0]`、`[!0:2]`
        if source.hasSuffix("]"), let open = source.lastIndex(of: "[") {
            let inner = String(source[source.index(after: open)..<source.index(before: source.endIndex)])
            var body = inner.trimmingCharacters(in: .whitespaces)

            var exclude = false
            if body.hasPrefix("!") {
                exclude = true
                body = String(body.dropFirst()).trimmingCharacters(in: .whitespaces)
            }

            var values: [Int] = []
            var slices: [Slice] = []

            for part in body.split(separator: ",", omittingEmptySubsequences: true) {
                let piece = part.trimmingCharacters(in: .whitespaces)
                if piece.contains(":") {
                    let comps = piece
                        .split(separator: ":", omittingEmptySubsequences: false)
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                    guard comps.count == 2 || comps.count == 3 else { continue }
                    let start = comps[0].isEmpty ? nil : Int(comps[0])
                    let end = comps[1].isEmpty ? nil : Int(comps[1])
                    let step = comps.count == 3 && !comps[2].isEmpty ? Int(comps[2]) : nil
                    if start != nil || end != nil || step != nil {
                        slices.append(Slice(start: start, end: end, step: step))
                    }
                } else if let value = Int(piece) {
                    values.append(value)
                }
            }

            guard !values.isEmpty || !slices.isEmpty else { return }

            parsed.indexMode = exclude ? .exclude : .select
            parsed.indexValues = values
            parsed.slices = slices
            text = String(source[..<open]).trimmingCharacters(in: .whitespaces)
            return
        }

        // B. `.N` / `!N` / `!0,2`（Android 旧写法，可出现在最右）
        let pattern = #"([.!])(\s*-?\d+(?:\s*,\s*-?\d+)*)\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
              let markRange = Range(match.range(at: 1), in: source),
              let valueRange = Range(match.range(at: 2), in: source) else {
            return
        }

        let numbers = String(source[valueRange])
            .split(separator: ",")
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard !numbers.isEmpty else { return }

        parsed.indexMode = source[markRange] == "!" ? .exclude : .select
        parsed.indexValues = numbers
        let cut = source.index(source.startIndex, offsetBy: match.range.location)
        text = String(source[..<cut]).trimmingCharacters(in: .whitespaces)
    }

    // MARK: - 工具

    /// 判断是否是 Legado 的「步骤前缀」，如 @tag.li
    static func isStepPrefix(_ value: String) -> Bool {
        if value == "children" { return true }
        for prefix in ["tag.", "class.", "id.", "text."] where value.hasPrefix(prefix) {
            return true
        }
        return false
    }

    /// 判断 `@` 之后是「级联选择器」而非属性名
    /// 属性名只允许字母数字 + `: - _`，含 `.` `#` `[` `>` `*` `,` 的都是选择器
    static func looksLikeSelector(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if isAttribute(trimmed) { return false }
        if trimmed.contains(" ") { return false }
        return trimmed.range(
            of: #"^[A-Za-z0-9_.#\[\]>:=*,-]+$"#,
            options: .regularExpression
        ) != nil
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
    /// 注意：`text.xxx` 由 ownTextFilter 承载，这里不再当标签名处理
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
        case slice(Int?, Int?, Int?)
        case filter(String)
        /// Jayway 函数：length() / size() / min() / max() / avg() / sum() / keys() / toNumber()
        case function(String)
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
                } else if key.hasSuffix("()") {
                    tokens.append(.function(String(key.dropLast(2)).lowercased()))
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
            let step = parts.count > 2 ? Int(parts[2]) : nil
            return .slice(start, end, step)
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
            // 函数作用于整个结果集（不是逐元素）
            if case .function(let name) = token {
                current = applyFunction(name, to: current)
                continue
            }

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

                case .slice(let start, let end, let step):
                    if let array = value as? [Any], !array.isEmpty {
                        let total = array.count
                        var lower = start ?? 0
                        if lower < 0 { lower += total }
                        var upper = end ?? total
                        if upper < 0 { upper += total }
                        lower = max(0, min(total, lower))
                        upper = max(0, min(total, upper))

                        let stride = step ?? 1
                        if stride >= 1 {
                            var index = lower
                            while index < upper {
                                next.append(array[index])
                                index += stride
                            }
                        } else {
                            // 负 step：从 upper-1 向下取（对应 jayway 的倒序切片）
                            var index = min(total - 1, upper - 1)
                            while index >= lower, index >= 0 {
                                next.append(array[index])
                                index += stride
                            }
                        }
                    }

                case .function:
                    // 已在 token 循环开头统一处理，这里仅为穷尽 switch
                    break

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

    /// Jayway 常用函数（对当前结果集求值）
    private static func applyFunction(_ name: String, to values: [Any]) -> [Any] {
        guard let first = values.first else { return [] }

        switch name {
        case "length", "size":
            if let array = first as? [Any] { return [array.count] }
            if let string = first as? String { return [string.count] }
            if let dict = first as? [String: Any] { return [dict.count] }
            return [values.count]

        case "keys":
            if let dict = first as? [String: Any] { return [Array(dict.keys)] }
            return []

        case "min", "max", "avg", "sum":
            var numbers: [Double] = []

            for value in values {
                if let number = value as? NSNumber {
                    numbers.append(number.doubleValue)
                } else if let array = value as? [Any] {
                    numbers.append(contentsOf: array.compactMap { ($0 as? NSNumber)?.doubleValue })
                }
            }

            guard !numbers.isEmpty else { return [] }

            switch name {
            case "min": return [numbers.min() ?? 0]
            case "max": return [numbers.max() ?? 0]
            case "avg": return [numbers.reduce(0, +) / Double(numbers.count)]
            default: return [numbers.reduce(0, +)]
            }

        case "tonumber":
            for value in values {
                if let string = value as? String, let number = Double(string) {
                    return [number]
                }
                if let number = value as? NSNumber { return [number] }
            }
            return []

        default:
            return values
        }
    }

    private static func matches(filter: String, item: Any) -> Bool {
        var expr = filter.trimmingCharacters(in: .whitespaces)
        if expr.hasPrefix("?") { expr = String(expr.dropFirst()) }
        expr = expr.trimmingCharacters(in: .whitespaces)
        if expr.hasPrefix("("), expr.hasSuffix(")") {
            expr = String(expr.dropFirst().dropLast())
        }
        expr = expr.trimmingCharacters(in: .whitespaces)

        // 逻辑组合：|| 任一成立、&& 全部成立（引号/括号内的分隔符不参与切分）
        let orParts = RuleSplitter.splitTopLevel(expr, separator: "||")
        if orParts.count > 1 {
            return orParts.contains { matches(filter: $0, item: item) }
        }

        let andParts = RuleSplitter.splitTopLevel(expr, separator: "&&")
        if andParts.count > 1 {
            return andParts.allSatisfy { matches(filter: $0, item: item) }
        }

        // 正则匹配（Jayway：$.list[?(@.name =~ /关键字/)]）
        if let range = expr.range(of: "=~") {
            let lhs = String(expr[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            var rhs = String(expr[range.upperBound...]).trimmingCharacters(in: .whitespaces)

            if rhs.hasPrefix("/"), rhs.hasSuffix("/"), rhs.count >= 2 {
                rhs = String(rhs.dropFirst().dropLast())
            }
            rhs = unquote(rhs)

            guard let leftValue = resolveOperand(lhs, item: item) else { return false }
            let leftText = stringValue(leftValue)
            return leftText.range(of: rhs, options: .regularExpression) != nil
        }

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
