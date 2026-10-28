// RuleEngine.swift 里定义的枚举，抽出来供 Linux 上的局部类型检查使用（不参与 App 编译）
enum RuleKind: String, CaseIterable {
    case jsonPath = "json"
    case xpath = "xpath"
    case css = "css"
    case regex = "regex"
    case js = "js"
}
