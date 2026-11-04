//
//  BookSource+CoreDataClass.swift
//  Legado-iOS
//
//  书源实体
//

import Foundation
import CoreData

@objc(BookSource)
public class BookSource: NSManagedObject {
    // MARK: - 基础信息
    @NSManaged public var sourceId: UUID
    @NSManaged public var bookSourceUrl: String
    @NSManaged public var bookSourceName: String
    @NSManaged public var bookSourceGroup: String?
    @NSManaged public var bookSourceType: Int32
    @NSManaged public var bookUrlPattern: String?
    
    // MARK: - 状态
    @NSManaged public var customOrder: Int32
    @NSManaged public var enabled: Bool
    @NSManaged public var enabledExplore: Bool
    @NSManaged public var enabledCookieJar: Bool
    
    // MARK: - 网络配置
    @NSManaged public var concurrentRate: String?
    @NSManaged public var header: String?
    @NSManaged public var loginUrl: String?
    @NSManaged public var loginUi: String?
    @NSManaged public var loginCheckJs: String?
    @NSManaged public var coverDecodeJs: String?
    @NSManaged public var jsLib: String?
    
    // MARK: - 注释
    @NSManaged public var bookSourceComment: String?
    @NSManaged public var variableComment: String?
    
    // MARK: - 统计
    @NSManaged public var lastUpdateTime: Int64
    @NSManaged public var respondTime: Int64
    @NSManaged public var weight: Int32
    
    // MARK: - URL
    @NSManaged public var exploreUrl: String?
    @NSManaged public var exploreScreen: String?
    @NSManaged public var searchUrl: String?
    
    // MARK: - 规则 (JSON 存储)
    @NSManaged public var ruleSearchData: Data?
    @NSManaged public var ruleExploreData: Data?
    @NSManaged public var ruleBookInfoData: Data?
    @NSManaged public var ruleTocData: Data?
    @NSManaged public var ruleContentData: Data?
    @NSManaged public var ruleReviewData: Data?
    
    // MARK: - 自定义变量
    @NSManaged public var variable: String?
    
    // MARK: - 关系
    @NSManaged public var books: NSSet?
}

// MARK: - Fetch Request
extension BookSource {
    @nonobjc class func fetchRequest() -> NSFetchRequest<BookSource> {
        return NSFetchRequest<BookSource>(entityName: "BookSource")
    }
}

// MARK: - 计算属性
extension BookSource {
    var displayName: String {
        if let group = bookSourceGroup, !group.isEmpty {
            return "\(bookSourceName) (\(group))"
        }
        return bookSourceName
    }
    
    var isAudio: Bool {
        bookSourceType == 1
    }

    var isImage: Bool {
        bookSourceType == 2
    }

    /// 当前版本只实现了文本（电子书）阅读，只有 type=0 的源能参与搜索/解析
    var supportsTextSearch: Bool {
        bookSourceType == 0
    }

    var typeDisplayName: String {
        switch bookSourceType {
        case 1: return "有声"
        case 2: return "漫画"
        case 3: return "文件"
        default: return "文本"
        }
    }

    /// 很多第三方书源不带 bookSourceType（或写成 0），只能用分组名/名称/域名做启发式补全。
    /// 返回 0 表示看不出来，保持文本。
    static func inferType(group: String?, url: String, name: String) -> Int32 {
        let haystack = [group ?? "", name, url].joined(separator: " ").lowercased()

        let audioKeywords = ["有声", "音频", "听书", "音乐", "歌曲", "评书", "audio", "music", "ting", "listen", "audiobook"]
        let imageKeywords = ["漫画", "图片", "图源", "写真", "cosplay", "manga", "comic", "manhua", "photo", "gallery", "hentai"]

        if audioKeywords.contains(where: { haystack.contains($0) }) { return 1 }
        if imageKeywords.contains(where: { haystack.contains($0) }) { return 2 }
        return 0
    }
    
    var isValid: Bool {
        !bookSourceUrl.isEmpty && !bookSourceName.isEmpty
    }
}

// MARK: - 规则结构体
extension BookSource {
    /// 发现规则
    struct ExploreRule: Codable {
        var exploreList: String? = nil
        var name: String? = nil
        var author: String? = nil
        var intro: String? = nil
        var bookUrl: String? = nil
        var coverUrl: String? = nil
        var lastChapter: String? = nil
        var kind: String? = nil
        var wordCount: String? = nil
    }

    /// 搜索规则
    struct SearchRule: Codable {
        var checkKeyWord: String? = nil
        var bookList: String? = nil
        var name: String? = nil
        var author: String? = nil
        var intro: String? = nil
        var bookUrl: String? = nil
        var coverUrl: String? = nil
        var lastChapter: String? = nil
        var wordCount: String? = nil
        var kind: String? = nil
    }

    /// 书籍信息规则
    struct BookInfoRule: Codable {
        var initRule: String? = nil
        var name: String? = nil
        var author: String? = nil
        var intro: String? = nil
        var coverUrl: String? = nil
        var tocUrl: String? = nil
        var lastChapter: String? = nil
        var wordCount: String? = nil
        var downloadUrls: String? = nil
        var kind: String? = nil
        var canReName: String? = nil

        enum CodingKeys: String, CodingKey {
            case initRule = "init"
            case name, author, intro, coverUrl, tocUrl, lastChapter, wordCount, downloadUrls, kind, canReName
        }
    }

    /// 目录规则
    struct TocRule: Codable {
        var chapterList: String? = nil
        var chapterName: String? = nil
        var chapterUrl: String? = nil
        var isVip: String? = nil
        var isPay: String? = nil
        var updateTime: String? = nil
        var nextTocUrl: String? = nil
        var isVolume: String? = nil
        var formatJs: String? = nil
        var preUpdateJs: String? = nil
    }

    /// 正文规则
    struct ContentRule: Codable {
        var content: String? = nil
        var subContent: String? = nil
        var title: String? = nil
        var nextContentUrl: String? = nil
        var webJs: String? = nil
        var sourceRegex: String? = nil
        var replaceRegex: String? = nil
        var imageStyle: String? = nil
        var payAction: String? = nil
        var callBackJs: String? = nil
    }
    
    /// 段评规则
    struct ReviewRule: Codable {
        var reviewList: String?
        var reviewContent: String?
        var reviewAuthor: String?
        var reviewTime: String?
    }
}

// MARK: - 规则访问器
extension BookSource {
    func getExploreRule() -> ExploreRule? {
        guard let data = ruleExploreData else { return nil }
        return try? JSONDecoder().decode(ExploreRule.self, from: data)
    }
    
    func setExploreRule(_ rule: ExploreRule) {
        ruleExploreData = try? JSONEncoder().encode(rule)
    }
    
    func getSearchRule() -> SearchRule? {
        guard let data = ruleSearchData else { return nil }
        return try? JSONDecoder().decode(SearchRule.self, from: data)
    }
    
    func setSearchRule(_ rule: SearchRule) {
        ruleSearchData = try? JSONEncoder().encode(rule)
    }
    
    func getBookInfoRule() -> BookInfoRule? {
        guard let data = ruleBookInfoData else { return nil }
        return try? JSONDecoder().decode(BookInfoRule.self, from: data)
    }
    
    func setBookInfoRule(_ rule: BookInfoRule) {
        ruleBookInfoData = try? JSONEncoder().encode(rule)
    }
    
    func getTocRule() -> TocRule? {
        guard let data = ruleTocData else { return nil }
        return try? JSONDecoder().decode(TocRule.self, from: data)
    }
    
    func setTocRule(_ rule: TocRule) {
        ruleTocData = try? JSONEncoder().encode(rule)
    }
    
    func getContentRule() -> ContentRule? {
        guard let data = ruleContentData else { return nil }
        return try? JSONDecoder().decode(ContentRule.self, from: data)
    }
    
    func setContentRule(_ rule: ContentRule) {
        ruleContentData = try? JSONEncoder().encode(rule)
    }
    
    func getReviewRule() -> ReviewRule? {
        guard let data = ruleReviewData else { return nil }
        return try? JSONDecoder().decode(ReviewRule.self, from: data)
    }
    
    func setReviewRule(_ rule: ReviewRule) {
        ruleReviewData = try? JSONEncoder().encode(rule)
    }
}

// MARK: - 初始化
extension BookSource {
    static func create(in context: NSManagedObjectContext) -> BookSource {
        let entity = NSEntityDescription.entity(forEntityName: "BookSource", in: context)!
        let source = BookSource(entity: entity, insertInto: context)
        source.sourceId = UUID()
        source.enabled = true
        source.enabledExplore = true
        source.enabledCookieJar = false
        source.bookSourceType = 0
        source.customOrder = 0
        source.weight = 0
        source.respondTime = 180000
        return source
    }
}

// MARK: - 书源能力识别（筛选与扫描用）

extension BookSource {

    /// 官方声明需要登录：loginUrl / loginUi / loginCheckJs 任一非空
    var declaredLogin: Bool {
        let fields = [loginUrl, loginUi, loginCheckJs]
        return fields.contains { !($0 ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// 规则里引用了登录相关 API（未声明但实际依赖登录）
    var usesLoginInRules: Bool {
        let keywords = [
            "java.getLoginInfo", "java.putLoginInfo", "java.hasLogin",
            "java.getHeaderMap", "java.getLoginHeader", "java.login(",
            "source.getLoginInfo"
        ]
        let text = ruleTextForScan
        return keywords.contains { text.contains($0) }
    }

    var requiresLogin: Bool { declaredLogin || usesLoginInRules }

    /// 是否声明了发现页
    var hasExplore: Bool {
        !(exploreUrl ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 拼出用于能力扫描的规则文本（规则字段是 JSON Data，先转字符串）
    var ruleTextForScan: String {
        var parts: [String] = [
            bookSourceUrl,
            searchUrl ?? "",
            exploreUrl ?? "",
            header ?? "",
            jsLib ?? ""
        ]

        for data in [ruleSearchData, ruleExploreData, ruleBookInfoData, ruleTocData, ruleContentData].compactMap({ $0 }) {
            if let text = String(data: data, encoding: .utf8) {
                parts.append(text)
            }
        }

        return parts.joined(separator: "\n")
    }
}

// MARK: - 发现分类（对齐 Android BookSource.exploreKinds）

extension BookSource {

    struct ExploreKindItem: Identifiable, Hashable {
        let name: String
        let url: String

        var id: String { "\(name)|\(url)" }
    }

    /// 解析 exploreUrl：`名称::地址` 用 `&&` 或换行分隔；
    /// `@js:` / `<js>` 形式需要 JS 引擎，暂返回空
    var exploreKinds: [ExploreKindItem] {
        guard let raw = exploreUrl?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return []
        }

        let lowered = raw.lowercased()
        if lowered.hasPrefix("@js:") || lowered.contains("<js>") {
            return []
        }

        var items: [ExploreKindItem] = []

        for line in raw.components(separatedBy: "\n") {
            for part in line.components(separatedBy: "&&") {
                let text = part.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }

                let comps = text.components(separatedBy: "::")
                if comps.count >= 2 {
                    let name = comps[0].trimmingCharacters(in: .whitespaces)
                    let url = comps.dropFirst().joined(separator: "::").trimmingCharacters(in: .whitespaces)
                    if !url.isEmpty {
                        items.append(ExploreKindItem(name: name.isEmpty ? "发现" : name, url: url))
                    }
                } else if text.contains("http") {
                    items.append(ExploreKindItem(name: "发现", url: text))
                }
            }
        }

        return items
    }
}

// MARK: - 登录信息（对齐 Android BaseSource 的 loginInfo）

/// 按书源存放登录信息（UserDefaults 明文，与 Android 一致）
enum LoginStore {

    private static func storageKey(for source: BookSource) -> String {
        "loginInfo:" + source.bookSourceUrl
    }

    /// 该源的全部登录信息
    static func all(for source: BookSource) -> [String: String] {
        UserDefaults.standard.dictionary(forKey: storageKey(for: source)) as? [String: String] ?? [:]
    }

    static func value(for source: BookSource, key name: String) -> String? {
        let info = all(for: source)
        guard let value = info[name], !value.isEmpty else { return nil }
        return value
    }

    static func setValue(_ value: String, for source: BookSource, key name: String) {
        var info = all(for: source)
        info[name] = value
        UserDefaults.standard.set(info, forKey: storageKey(for: source))
    }

    /// name 为空时清除该源全部登录信息
    static func remove(for source: BookSource, key name: String? = nil) {
        guard let name else {
            UserDefaults.standard.removeObject(forKey: storageKey(for: source))
            return
        }
        var info = all(for: source)
        info.removeValue(forKey: name)
        UserDefaults.standard.set(info, forKey: storageKey(for: source))
    }

    static func hasLoginInfo(_ source: BookSource) -> Bool {
        !all(for: source).isEmpty
    }
}

extension BookSource {

    /// 登录后追加的请求头：loginInfo 里的 `header` 字段是 JSON 对象字符串
    /// 对应 Android `BaseSource.getLoginHeaderMap()`
    var loginHeaderMap: [String: String] {
        guard let raw = LoginStore.value(for: self, key: "header"),
              let data = raw.data(using: .utf8),
              let map = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        return map
    }

    /// 是否声明了登录表单
    var hasLoginForm: Bool {
        guard let loginUi, !loginUi.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return true
    }

    /// 是否已有登录信息
    var hasLogin: Bool {
        LoginStore.hasLoginInfo(self) || !loginHeaderMap.isEmpty
    }
}

// MARK: - 登录表单（对齐 Android RowUi / LoginUiV2）

struct LoginRow: Decodable, Identifiable {
    let name: String
    let type: String
    let action: String?
    let key: String?
    let hint: String?
    let options: [String]?

    var id: String { (key ?? name) + "|" + type }

    /// 是否为需要用户输入的控件
    var isInput: Bool {
        type == "text" || type == "password" || type == "select" || type == "toggle"
    }
}

enum LoginUiParser {

    /// 兼容两种格式：
    /// - V1：`[{"name":"账号","type":"text","key":"account"}, …]`
    /// - V2：`{"version":2,"rows":[…]}`
    static func parse(_ raw: String?) -> [LoginRow] {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let data = raw.data(using: .utf8) else {
            return []
        }

        let decoder = JSONDecoder()

        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let rows = object["rows"],
           let rowData = try? JSONSerialization.data(withJSONObject: rows) {
            return (try? decoder.decode([LoginRow].self, from: rowData)) ?? []
        }

        return (try? decoder.decode([LoginRow].self, from: data)) ?? []
    }
}

// MARK: - 登录态校验

enum LoginRunner {

    /// 执行 loginCheckJs（未配置时按「有登录信息即视为已登录」）
    static func check(_ source: BookSource) -> Bool {
        guard let script = source.loginCheckJs?.trimmingCharacters(in: .whitespacesAndNewlines),
              !script.isEmpty else {
            return source.hasLogin
        }

        let context = ExecutionContext()
        context.source = source
        context.baseURL = URL(string: source.bookSourceUrl)

        let bridge = JSBridge()
        bridge.context = context

        guard let jsContext = JSContext() else { return source.hasLogin }

        bridge.inject(into: jsContext)
        jsContext.setObject(source.bookSourceUrl, forKeyedSubscript: "baseUrl" as NSString)
        jsContext.setObject(source.bookSourceUrl, forKeyedSubscript: "result" as NSString)

        guard let value = jsContext.evaluateScript(script), !value.isUndefined, !value.isNull else {
            return source.hasLogin
        }

        let text = (value.toString() ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return text == "true" || text == "1" || text == "yes"
    }
}
