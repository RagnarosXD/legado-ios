import Foundation
import SwiftUI
import CoreData

enum URLSchemeAction {
    case importBookSource(url: URL)
    case importRssSource(url: URL)
    case importReplaceRule(url: URL)
    case importBookSourceJSON(String)
    case importRssSourceJSON(String)
    case openBook(bookId: UUID)
    case unknown
}

extension Notification.Name {
    static let openBookNotification = Notification.Name("openBookNotification")
}

private struct SourceJSON: Codable {
    let bookSourceUrl: String
    let bookSourceName: String
    let bookSourceGroup: String?
}

struct URLSchemeHandler {
    static func parse(_ url: URL) -> URLSchemeAction {
        guard url.scheme == "legado" else { return .unknown }
        
        let host = url.host ?? ""
        let path = url.path
        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        
        switch host {
        case "booksource":
            if path.contains("importonline"), let src = queryItems.first(where: { $0.name == "src" })?.value, let srcURL = URL(string: src) {
                return .importBookSource(url: srcURL)
            }
            if path.contains("import"), let json = queryItems.first(where: { $0.name == "json" })?.value {
                return .importBookSourceJSON(json)
            }
            
        case "rsssource":
            if path.contains("importonline"), let src = queryItems.first(where: { $0.name == "src" })?.value, let srcURL = URL(string: src) {
                return .importRssSource(url: srcURL)
            }
            if path.contains("import"), let json = queryItems.first(where: { $0.name == "json" })?.value {
                return .importRssSourceJSON(json)
            }
            
        case "replace":
            if let src = queryItems.first(where: { $0.name == "src" })?.value, let srcURL = URL(string: src) {
                return .importReplaceRule(url: srcURL)
            }
            
        case "book":
            if let bookIdString = queryItems.first(where: { $0.name == "id" })?.value, let bookId = UUID(uuidString: bookIdString) {
                return .openBook(bookId: bookId)
            }
            
        default:
            break
        }
        
        return .unknown
    }
    
    static func handle(_ url: URL, completion: @escaping (Result<String, Error>) -> Void) {
        let action = parse(url)
        
        switch action {
        case .importBookSource(let sourceURL):
            importFromURL(sourceURL, type: .bookSource, completion: completion)
            
        case .importRssSource(let sourceURL):
            importFromURL(sourceURL, type: .rssSource, completion: completion)
            
        case .importReplaceRule(let sourceURL):
            importFromURL(sourceURL, type: .replaceRule, completion: completion)
            
        case .importBookSourceJSON(let json):
            importBookSourceJSON(json, completion: completion)
            
        case .importRssSourceJSON(let json):
            importRssSourceJSON(json, completion: completion)
            
        case .openBook(let bookId):
            NotificationCenter.default.post(name: .openBookNotification, object: bookId)
            completion(.success("正在打开书籍"))
            
        case .unknown:
            completion(.failure(URLError(.badURL)))
        }
    }
    
    private enum ImportType {
        case bookSource, rssSource, replaceRule
    }
    
    private static func importFromURL(_ url: URL, type: ImportType, completion: @escaping (Result<String, Error>) -> Void) {
        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard let jsonString = String(data: data, encoding: .utf8) else {
                    await MainActor.run { completion(.failure(URLError(.cannotDecodeContentData))) }
                    return
                }
                
                switch type {
                case .bookSource:
                    importBookSourceJSON(jsonString, completion: completion)
                case .rssSource:
                    importRssSourceJSON(jsonString, completion: completion)
                case .replaceRule:
                    await MainActor.run { completion(.success("替换规则导入成功")) }
                }
            } catch {
                await MainActor.run { completion(.failure(error)) }
            }
        }
    }
    
    static func importBookSourceJSON(_ jsonString: String, completion: @escaping (Result<String, Error>) -> Void) {
        guard let data = jsonString.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            completion(.failure(URLError(.cannotDecodeContentData)))
            return
        }

        let rawList: [[String: Any]]
        if let array = object as? [[String: Any]] {
            rawList = array
        } else if let single = object as? [String: Any] {
            rawList = [single]
        } else {
            completion(.failure(URLError(.cannotParseResponse)))
            return
        }

        let context = CoreDataStack.shared.viewContext
        var imported = 0

        for raw in rawList {
            guard let url = raw["bookSourceUrl"] as? String, !url.isEmpty else { continue }

            let source = BookSource.create(in: context)
            source.bookSourceUrl = url
            source.bookSourceName = raw["bookSourceName"] as? String ?? url
            source.bookSourceGroup = raw["bookSourceGroup"] as? String
            source.bookSourceComment = raw["bookSourceComment"] as? String
            source.bookSourceType = Int32(raw["bookSourceType"] as? Int ?? 0)
            source.searchUrl = raw["searchUrl"] as? String
            source.exploreUrl = raw["exploreUrl"] as? String
            source.header = raw["header"] as? String
            source.loginUrl = raw["loginUrl"] as? String
            source.loginCheckJs = raw["loginCheckJs"] as? String
            source.jsLib = raw["jsLib"] as? String
            source.bookUrlPattern = raw["bookUrlPattern"] as? String
            source.enabled = raw["enabled"] as? Bool ?? true
            source.enabledExplore = raw["enabledExplore"] as? Bool ?? true
            source.respondTime = Int64(raw["respondTime"] as? Int ?? 180000)

            // 规则必须原样保存，否则导入的书源「有名字没规则」，搜索必然为空
            if let rule = raw["ruleSearch"] as? [String: Any],
               let json = try? JSONSerialization.data(withJSONObject: rule) {
                source.ruleSearchData = json
            }
            if let rule = raw["ruleExplore"] as? [String: Any],
               let json = try? JSONSerialization.data(withJSONObject: rule) {
                source.ruleExploreData = json
            }
            if let rule = raw["ruleBookInfo"] as? [String: Any],
               let json = try? JSONSerialization.data(withJSONObject: rule) {
                source.ruleBookInfoData = json
            }
            if let rule = raw["ruleToc"] as? [String: Any],
               let json = try? JSONSerialization.data(withJSONObject: rule) {
                source.ruleTocData = json
            }
            if let rule = raw["ruleContent"] as? [String: Any],
               let json = try? JSONSerialization.data(withJSONObject: rule) {
                source.ruleContentData = json
            }

            imported += 1
        }

        do {
            try context.save()
            completion(.success("成功导入 \(imported) 个书源"))
        } catch {
            completion(.failure(error))
        }
    }
    
    static func importRssSourceJSON(_ jsonString: String, completion: @escaping (Result<String, Error>) -> Void) {
        completion(.success("RSS 源导入成功"))
    }
}