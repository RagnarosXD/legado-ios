//
//  SourceViewModel.swift
//  Legado-iOS
//
//  书源管理 ViewModel
//

import Foundation
import CoreData

@MainActor
class SourceViewModel: ObservableObject {
    @Published var sources: [BookSource] = []
    @Published var errorMessage: String?
    
    func loadSources() async {
        do {
            let request: NSFetchRequest<BookSource> = BookSource.fetchRequest()
            request.sortDescriptors = [NSSortDescriptor(key: "customOrder", ascending: true)]
            request.includesPendingChanges = false
            
            sources = try CoreDataStack.shared.viewContext.fetch(request)
        } catch {
            errorMessage = "加载书源失败：\(error.localizedDescription)"
        }
    }
    
    func createSource(
        name: String,
        url: String,
        group: String,
        type: Int32,
        searchUrl: String,
        exploreUrl: String,
        ruleSearch: String,
        ruleBookInfo: String,
        ruleToc: String,
        ruleContent: String
    ) -> Bool {
        let context = CoreDataStack.shared.viewContext
        let source = BookSource.create(in: context)
        
        source.bookSourceName = name
        source.bookSourceUrl = url
        source.bookSourceGroup = group.isEmpty ? nil : group
        source.bookSourceType = type
        source.searchUrl = searchUrl.isEmpty ? nil : searchUrl
        source.exploreUrl = exploreUrl.isEmpty ? nil : exploreUrl
        do {
            source.ruleSearchData = try encodeRuleJSON(from: ruleSearch)
            source.ruleBookInfoData = try encodeRuleJSON(from: ruleBookInfo)
            source.ruleTocData = try encodeRuleJSON(from: ruleToc)
            source.ruleContentData = try encodeRuleJSON(from: ruleContent)
        } catch {
            context.rollback()
            errorMessage = "保存失败：\(error.localizedDescription)"
            return false
        }
        
        do {
            try CoreDataStack.shared.save()
            Task { await loadSources() }
            return true
        } catch {
            context.rollback()
            errorMessage = "保存失败：\(error.localizedDescription)"
            Task { await loadSources() }
            return false
        }
    }
    
    func updateSource(
        _ source: BookSource,
        name: String,
        url: String,
        group: String,
        type: Int32,
        searchUrl: String,
        exploreUrl: String,
        ruleSearch: String,
        ruleBookInfo: String,
        ruleToc: String,
        ruleContent: String
    ) -> Bool {
        let context = CoreDataStack.shared.viewContext
        source.bookSourceName = name
        source.bookSourceUrl = url
        source.bookSourceGroup = group.isEmpty ? nil : group
        source.bookSourceType = type
        source.searchUrl = searchUrl.isEmpty ? nil : searchUrl
        source.exploreUrl = exploreUrl.isEmpty ? nil : exploreUrl
        do {
            source.ruleSearchData = try encodeRuleJSON(from: ruleSearch)
            source.ruleBookInfoData = try encodeRuleJSON(from: ruleBookInfo)
            source.ruleTocData = try encodeRuleJSON(from: ruleToc)
            source.ruleContentData = try encodeRuleJSON(from: ruleContent)
        } catch {
            context.rollback()
            errorMessage = "保存失败：\(error.localizedDescription)"
            return false
        }
        
        do {
            try CoreDataStack.shared.save()
            Task { await loadSources() }
            return true
        } catch {
            context.rollback()
            errorMessage = "保存失败：\(error.localizedDescription)"
            Task { await loadSources() }
            return false
        }
    }
    
    func deleteSource(_ source: BookSource) {
        deleteSources(ids: [source.sourceId])
    }

    /// 批量删除：先从内存数组摘掉再保存。
    /// 之前是「只 delete + 异步刷新」，SwiftUI 下一帧仍会为已删除对象求 `sourceId`，
    /// 触发 invalidated object 访问，单个/批量删除都会闪退。
    func deleteSources(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }

        let context = CoreDataStack.shared.viewContext
        let targets = sources.filter { ids.contains($0.sourceId) }
        for source in targets {
            context.delete(source)
        }

        // 关键：同步移除，界面不会再渲染到已失效对象
        sources.removeAll { ids.contains($0.sourceId) }

        do {
            try CoreDataStack.shared.save()
            AppLogger.info("Source", "删除 \(targets.count) 个书源，剩余 \(sources.count)")
        } catch {
            context.rollback()
            errorMessage = "删除失败：\(error.localizedDescription)"
            Task { await loadSources() }
        }
    }

    func deleteSources(at indexSet: IndexSet) {
        let ids = Set(indexSet.compactMap { index in
            sources.indices.contains(index) ? sources[index].sourceId : nil
        })
        deleteSources(ids: ids)
    }
    
    func importFromURL(_ urlString: String) async -> Int {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)

        if let legado = parseLegadoImportLink(trimmed) {
            if legado.src.hasPrefix("[") || legado.src.hasPrefix("{") {
                return importFromText(legado.src)
            }
            return await importFromRemoteURL(legado.src, requestWithoutUA: legado.requestWithoutUA)
        }

        return await importFromRemoteURL(trimmed, requestWithoutUA: false)
    }

    private func importFromRemoteURL(_ urlString: String, requestWithoutUA: Bool) async -> Int {
        guard let url = URL(string: urlString) else {
            errorMessage = "无效的 URL"
            return 0
        }

        do {
            let data: Data
            if requestWithoutUA {
                var request = URLRequest(url: url)
                request.setValue("null", forHTTPHeaderField: "User-Agent")
                let (d, _) = try await URLSession.shared.data(for: request)
                data = d
            } else {
                let (d, _) = try await URLSession.shared.data(from: url)
                data = d
            }
            if let json = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                return importFromJSON(json)
            }
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return importSingleSource(json)
            }
            errorMessage = "导入失败：不支持的 JSON 格式"
            return 0
        } catch {
            errorMessage = "导入失败：\(error.localizedDescription)"
            return 0
        }
    }

    private func parseLegadoImportLink(_ input: String) -> (src: String, requestWithoutUA: Bool)? {
        guard let url = URL(string: input), url.scheme == "legado" else {
            return nil
        }

        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let srcItem = components.queryItems?.first(where: { $0.name == "src" }),
              let srcValue = srcItem.value, !srcValue.isEmpty else {
            return nil
        }

        let decoded = srcValue.removingPercentEncoding ?? srcValue
        var src = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
        var requestWithoutUA = false
        if src.hasSuffix("#requestWithoutUA") {
            requestWithoutUA = true
            src = String(src.dropLast("#requestWithoutUA".count))
        }

        if src.isEmpty { return nil }
        return (src: src, requestWithoutUA: requestWithoutUA)
    }
    
    func importFromText(_ text: String) -> Int {
        guard let data = text.data(using: .utf8) else {
            errorMessage = "无效的文本"
            return 0
        }
        
        do {
            if let json = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                return importFromJSON(json)
            } else if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return importSingleSource(json)
            }
            errorMessage = "导入失败：不支持的 JSON 格式"
            return 0
        } catch {
            errorMessage = "解析 JSON 失败：\(error.localizedDescription)"
            return 0
        }
    }
    
    private func importFromJSON(_ sources: [[String: Any]]) -> Int {
        let context = CoreDataStack.shared.viewContext

        var importedCount = 0
        for sourceData in sources {
            guard let url = sourceData["bookSourceUrl"] as? String, !url.isEmpty,
                  let name = sourceData["bookSourceName"] as? String, !name.isEmpty else {
                continue
            }

            let source = findOrCreateSource(for: sourceData, in: context)
            source.bookSourceUrl = url
            source.bookSourceName = name
            applySourceData(source, sourceData)
            importedCount += 1
        }
        
        do {
            try CoreDataStack.shared.save()
            Task { await loadSources() }
            return importedCount
        } catch {
            context.rollback()
            errorMessage = "导入失败：\(error.localizedDescription)"
            Task { await loadSources() }
            return 0
        }
    }
    
    private func importSingleSource(_ sourceData: [String: Any]) -> Int {
        let context = CoreDataStack.shared.viewContext
        guard let url = sourceData["bookSourceUrl"] as? String, !url.isEmpty,
              let name = sourceData["bookSourceName"] as? String, !name.isEmpty else {
            errorMessage = "导入失败：书源数据缺少必要字段"
            return 0
        }

        let source = findOrCreateSource(for: sourceData, in: context)
        source.bookSourceUrl = url
        source.bookSourceName = name
        applySourceData(source, sourceData)

        do {
            try CoreDataStack.shared.save()
            Task { await loadSources() }
            return 1
        } catch {
            context.rollback()
            errorMessage = "导入失败：\(error.localizedDescription)"
            Task { await loadSources() }
            return 0
        }
    }

    private func int32Value(_ value: Any?) -> Int32? {
        switch value {
        case let n as NSNumber:
            return n.int32Value
        case let i as Int:
            return Int32(i)
        case let s as String:
            return Int32(s.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }

    private func int64Value(_ value: Any?) -> Int64? {
        switch value {
        case let n as NSNumber:
            return n.int64Value
        case let i as Int:
            return Int64(i)
        case let s as String:
            return Int64(s.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }

    private func boolValue(_ value: Any?) -> Bool? {
        switch value {
        case let b as Bool:
            return b
        case let n as NSNumber:
            return n.boolValue
        case let s as String:
            let v = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["true", "1", "yes", "y"].contains(v) { return true }
            if ["false", "0", "no", "n"].contains(v) { return false }
            return nil
        default:
            return nil
        }
    }

    private func jsonDataValue(_ value: Any?) -> Data? {
        guard let value else { return nil }
        guard JSONSerialization.isValidJSONObject(value) else { return nil }
        return try? JSONSerialization.data(withJSONObject: value)
    }

    private func findOrCreateSource(for data: [String: Any], in context: NSManagedObjectContext) -> BookSource {
        let url = data["bookSourceUrl"] as? String ?? ""
        if !url.isEmpty {
            let request: NSFetchRequest<BookSource> = BookSource.fetchRequest()
            request.fetchLimit = 1
            request.predicate = NSPredicate(format: "bookSourceUrl == %@", url)
            if let existing = try? context.fetch(request).first {
                return existing
            }
        }
        return BookSource.create(in: context)
    }

    private func encodeRuleJSON(from text: String) throws -> Data? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return nil
        }
        guard let data = trimmed.data(using: .utf8) else {
            throw SourceValidationError.invalidEncoding
        }
        let jsonObject = try JSONSerialization.jsonObject(with: data)
        return try JSONSerialization.data(withJSONObject: jsonObject)
    }
    
    private func applySourceData(_ source: BookSource, _ data: [String: Any]) {
        source.bookSourceGroup = data["bookSourceGroup"] as? String
        if let v = int32Value(data["bookSourceType"]) { source.bookSourceType = v }
        if let v = int32Value(data["customOrder"]) { source.customOrder = v }
        if let v = boolValue(data["enabled"]) { source.enabled = v }
        if let v = boolValue(data["enabledExplore"]) { source.enabledExplore = v }
        if let v = boolValue(data["enabledCookieJar"]) { source.enabledCookieJar = v }
        if let v = int32Value(data["weight"]) { source.weight = v }
        if let v = int64Value(data["respondTime"]) { source.respondTime = v }
        if let v = int64Value(data["lastUpdateTime"]) { source.lastUpdateTime = v }

        source.bookUrlPattern = data["bookUrlPattern"] as? String
        source.concurrentRate = data["concurrentRate"] as? String
        source.header = data["header"] as? String
        source.loginUrl = data["loginUrl"] as? String
        source.loginUi = data["loginUi"] as? String
        source.loginCheckJs = data["loginCheckJs"] as? String
        source.coverDecodeJs = data["coverDecodeJs"] as? String
        source.jsLib = data["jsLib"] as? String

        source.bookSourceComment = data["bookSourceComment"] as? String
        source.variableComment = data["variableComment"] as? String
        source.variable = data["variable"] as? String

        source.searchUrl = data["searchUrl"] as? String
        source.exploreUrl = data["exploreUrl"] as? String
        source.exploreScreen = data["exploreScreen"] as? String

        if let v = jsonDataValue(data["ruleSearch"]) { source.ruleSearchData = v }
        if let v = jsonDataValue(data["ruleExplore"]) { source.ruleExploreData = v }
        if let v = jsonDataValue(data["ruleBookInfo"]) { source.ruleBookInfoData = v }
        if let v = jsonDataValue(data["ruleToc"]) { source.ruleTocData = v }
        if let v = jsonDataValue(data["ruleContent"]) { source.ruleContentData = v }
        if let v = jsonDataValue(data["ruleReview"]) { source.ruleReviewData = v }
    }
    
    /// 给没有类型声明的书源做启发式识别（分组名/名称/域名），返回改动数量
    @discardableResult
    func inferSourceTypes() -> Int {
        var changed = 0
        for source in sources where source.bookSourceType == 0 {
            let inferred = BookSource.inferType(
                group: source.bookSourceGroup,
                url: source.bookSourceUrl,
                name: source.bookSourceName
            )
            if inferred != 0 {
                source.bookSourceType = inferred
                changed += 1
            }
        }
        if changed > 0 {
            try? CoreDataStack.shared.save()
        }
        return changed
    }

    func exportAllSources() -> Data? {
        let exportSources = sources.map { ExportableSource(from: $0) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            return try encoder.encode(exportSources)
        } catch {
            errorMessage = "导出失败：\(error.localizedDescription)"
            return nil
        }
    }
}

private enum SourceValidationError: LocalizedError {
    case invalidEncoding

    var errorDescription: String? {
        switch self {
        case .invalidEncoding:
            return "规则内容编码无效"
        }
    }
}
