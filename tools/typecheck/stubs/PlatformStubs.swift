// 仅用于 Linux 上的类型检查：把 iOS 专有的 JavaScriptCore / Kanna / CoreData 实体用最小桩替代。
// 这些桩不参与 App 编译（Excluded from target sources 之外，只在 CI 的临时包里拷贝使用）。

import Foundation

// MARK: - JavaScriptCore 桩

public final class JSValue {
    public init?(newObjectIn context: JSContext) {}
    public init?(object: Any, in context: JSContext) {}
    public func setObject(_ object: Any?, forKeyedSubscript key: NSString) {}
    public func toString() -> String? { nil }
}

public final class JSContext {
    public init?() {}
    public func setValue(_ value: Any?, forKey key: String) {}
    public func evaluateScript(_ script: String) -> JSValue? { nil }
}

// MARK: - Kanna 桩

public protocol XMLElement {
    var text: String? { get }
    var toHTML: String? { get }
}

public struct StubElement: XMLElement {
    public var text: String?
    public var toHTML: String?
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
    public var loginUrl: String?
    public var header: String?
}

// MARK: - JSBridge 使用真实实现（JSBridge.swift 一起编译进临时包）
