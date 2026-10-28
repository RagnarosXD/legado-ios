//
//  RuleEngineTests.swift
//  Legado-iOSTests
//
//  规则引擎单元测试：覆盖 Legado 书源规则的真实语法（离线，不依赖网络）
//

import XCTest
@testable import Legado

final class RuleEngineTests: XCTestCase {

    var ruleEngine: RuleEngine!
    var context: ExecutionContext!

    private let html = """
    <html><body>
      <div class="book-list">
        <div class="book">
          <h2 class="title">三体</h2>
          <span class="author">刘慈欣</span>
          <a class="link" href="/book/1">详情</a>
        </div>
        <div class="book">
          <h2 class="title">球状闪电</h2>
          <span class="author">刘慈欣</span>
          <a class="link" href="/book/2">详情</a>
        </div>
      </div>
    </body></html>
    """

    override func setUp() async throws {
        try await super.setUp()
        ruleEngine = RuleEngine()
        context = ExecutionContext()
    }

    override func tearDown() async throws {
        ruleEngine = nil
        context = nil
        try await super.tearDown()
    }

    // MARK: - JSONPath

    func testJSONPathParser_simple() throws {
        let json = """
        { "book": { "name": "测试书籍", "author": "作者" } }
        """

        context.jsonString = json
        let result = try ruleEngine.executeSingle(rule: "$.book.name", context: context)

        XCTAssertEqual(result.string, "测试书籍")
    }

    func testJSONPathParser_array() throws {
        let json = """
        { "books": [ { "name": "书籍 1" }, { "name": "书籍 2" } ] }
        """

        context.jsonString = json
        let result = try ruleEngine.executeSingle(rule: "$.books[0].name", context: context)

        XCTAssertEqual(result.string, "书籍 1")
    }

    func testJSONPathParser_wildcardAndRecursive() throws {
        let json = """
        { "data": [ { "name": "A" }, { "name": "B" } ] }
        """

        context.jsonString = json

        let wildcard = try ruleEngine.executeSingle(rule: "$.data[*].name", context: context)
        XCTAssertEqual(wildcard.text, "A\nB")

        let recursive = try ruleEngine.executeSingle(rule: "$..name", context: context)
        XCTAssertEqual(recursive.text, "A\nB")
    }

    // MARK: - CSS / Legado 默认语法

    func testCSSParser_simple() throws {
        context.htmlString = html

        let result = try ruleEngine.executeSingle(rule: "div.book h2@text", context: context)
        XCTAssertEqual(result.string, "三体")
    }

    /// 回归测试：列表项解析出来的元素必须能作为「作用域根」继续求值字段规则
    func testFieldRuleInsideScopedElement() throws {
        let elements = try ruleEngine.getElements(ruleStr: "class.book", body: html, baseUrl: "https://example.com")

        XCTAssertEqual(elements.count, 2)

        let firstName = ruleEngine.getString(ruleStr: "class.title@text",
                                            elementContext: elements[0],
                                            baseUrl: "https://example.com")
        XCTAssertEqual(firstName, "三体")

        let secondUrl = ruleEngine.getString(ruleStr: "a@href",
                                             elementContext: elements[1],
                                             baseUrl: "https://example.com")
        XCTAssertEqual(secondUrl, "https://example.com/book/2")
    }

    func testLegadoDefaultSyntax() throws {
        let element = ElementContext(element: html, baseUrl: "https://example.com")

        XCTAssertEqual(ruleEngine.getString(ruleStr: "id.none@text", elementContext: element), "")
        XCTAssertEqual(ruleEngine.getString(ruleStr: "class.book!1@tag.h2@text", elementContext: element), "球状闪电")
        XCTAssertEqual(ruleEngine.getString(ruleStr: "tag.h2@text", elementContext: element), "三体")
    }

    func testReplaceRule() throws {
        let element = ElementContext(element: html, baseUrl: "https://example.com")

        // ##正则##替换
        XCTAssertEqual(ruleEngine.getString(ruleStr: "class.title@text##三体##三体：全集", elementContext: element),
                       "三体：全集")
        // 分组引用
        XCTAssertEqual(ruleEngine.getString(ruleStr: "class.title@text##(三)体##$1", elementContext: element),
                       "三")
    }

    func testOrAndRules() throws {
        let element = ElementContext(element: html, baseUrl: "https://example.com")

        XCTAssertEqual(ruleEngine.getString(ruleStr: "id.missing@text||class.author@text", elementContext: element),
                       "刘慈欣")
    }

    // MARK: - XPath

    func testXPathParser_simple() throws {
        context.htmlString = html

        let result = try ruleEngine.executeSingle(rule: "//h2", context: context)
        XCTAssertEqual(result.string, "三体")
    }

    // MARK: - 正则

    func testRegexParser() throws {
        context.document = "第 123 章 标题"

        let result = try ruleEngine.executeSingle(rule: "regex:第\\d+ 章", context: context)
        XCTAssertEqual(result.string, "第 123 章")
    }

    // MARK: - JavaScript

    func testJavaScriptParser() throws {
        context.document = "hello"

        let result = try ruleEngine.executeSingle(rule: "@js:\"hello\".toUpperCase()", context: context)
        XCTAssertEqual(result.string, "HELLO")
    }

    func testJavaScriptJavaApi() throws {
        let result = try ruleEngine.executeSingle(rule: "@js:java.base64Encode(\"hi\")", context: context)
        XCTAssertEqual(result.string, "aGk=")

        let md5 = try ruleEngine.executeSingle(rule: "@js:java.md5Encode(\"abc\")", context: context)
        XCTAssertEqual(md5.string, "900150983cd24fb0d6963f7d28e17f72")
    }

    // MARK: - 性能

    func testPerformance() throws {
        let json = """
        { "book": { "name": "测试", "author": "作者" } }
        """
        context.jsonString = json

        measure {
            for _ in 0..<100 {
                _ = try? ruleEngine.executeSingle(rule: "$.book.name", context: context)
            }
        }
    }
}
