// 仅用于 Linux 上的类型检查：把 iOS 专有的 JavaScriptCore / Kanna / CoreData 实体用最小桩替代。
// 这些桩不参与 App 编译（Excluded from target sources 之外，只在 CI 的临时包里拷贝使用）。

import Foundation

// MARK: - JavaScriptCore 桩

public final class JSValue {
    public init?(newObjectIn context: JSContext) {}
    public init?(object: Any, in context: JSContext) {}
    public func setObject(_ object: Any?, forKeyedSubscript key: NSString) {}
    public func toString() -> String? { nil }
    public var isUndefined: Bool { false }
    public var isNull: Bool { false }
    public var isNumber: Bool { false }
    public func toDouble() -> Double { 0 }
}

public final class JSContext {
    public init?() {}
    public func setValue(_ value: Any?, forKey key: String) {}
    public func setObject(_ object: Any?, forKeyedSubscript key: NSString) {}
    public func evaluateScript(_ script: String) -> JSValue? { nil }
}

// MARK: - Kanna 桩

public protocol XMLElement {
    var text: String? { get }
    var toHTML: String? { get }
    /// Kanna 的 CSS 选择（真实实现返回 XPathObject，可迭代）
    func css(_ selector: String) -> [XMLElement]
    /// 属性取值：element["href"]
    subscript(attribute: String) -> String? { get }
}

public struct StubElement: XMLElement {
    public var text: String?
    public var toHTML: String?

    public func css(_ selector: String) -> [XMLElement] { [] }

    public subscript(attribute: String) -> String? { nil }
}

public enum Kanna {
    public static func HTML(html: String, encoding: String.Encoding) throws -> StubDocument {
        StubDocument()
    }
}

public struct StubDocument {
    public func xpath(_ path: String) -> [XMLElement] { [] }
}

// MARK: - CoreData 实体桩

public final class BookSource {
    public var bookSourceUrl: String = ""
    public var bookSourceName: String?
    public var bookSourceGroup: String?
    public var bookSourceType: Int32 = 0
    public var loginUrl: String?
    public var loginUi: String?
    public var loginCheckJs: String?
    public var header: String?
}

// MARK: - 登录态桩（Linux 侧只需要类型签名）

public enum LoginStore {
    public static func all(for source: BookSource) -> [String: String] { [:] }
    public static func value(for source: BookSource, key: String) -> String? { nil }
    public static func setValue(_ value: String, for source: BookSource, key: String) {}
    public static func remove(for source: BookSource, key: String? = nil) {}
    public static func hasLoginInfo(_ source: BookSource) -> Bool { false }
}

extension BookSource {
    public var loginHeaderMap: [String: String] { [:] }
    public var hasLoginForm: Bool { false }
    public var hasLogin: Bool { false }
}

// MARK: - JSBridge 使用真实实现（JSBridge.swift 一起编译进临时包）
