//
//  SourceSubscriptionManager.swift
//  Legado-iOS
//
//  书源订阅管理器 - 支持从网络订阅源自动更新书源
//  P2-T5 实现
//

import Foundation
import CoreData

// MARK: - 书源订阅配置

struct SourceSubscription: Identifiable, Codable {
    let id: UUID
    var name: String
    var url: String
    var lastUpdateTime: Date?
    var autoUpdate: Bool
    var updateInterval: TimeInterval // 秒
    var enabled: Bool
    
    init(name: String, url: String, autoUpdate: Bool = true, updateInterval: TimeInterval = 86400) {
        self.id = UUID()
        self.name = name
        self.url = url
        self.lastUpdateTime = nil
        self.autoUpdate = autoUpdate
        self.updateInterval = updateInterval
        self.enabled = true
    }
}

// MARK: - 书源订阅管理器

@MainActor
class SourceSubscriptionManager: ObservableObject {

    static let shared = SourceSubscriptionManager()
    
    // MARK: - Published 属性
    
    @Published private(set) var subscriptions: [SourceSubscription] = []
    @Published var isUpdating = false
    @Published var lastUpdateError: String?
    @Published var updateProgress: Double = 0
    /// 当前阶段描述（下载 / 解析 / 导入 320/800）
    @Published var updateStage: String?
    
    // MARK: - 私有属性
    
    private let subscriptionsKey = "source_subscriptions"
    private let lastUpdateKey = "source_subscription_last_update"
    
    // MARK: - 初始化
    
    init() {
        loadSubscriptions()
    }
    
    // MARK: - 公开方法
    
    /// 添加订阅
    func addSubscription(name: String, url: String, autoUpdate: Bool = true) {
        let subscription = SourceSubscription(name: name, url: url, autoUpdate: autoUpdate)
        subscriptions.append(subscription)
        saveSubscriptions()
    }
    
    /// 删除订阅
    func removeSubscription(at index: Int) {
        guard subscriptions.indices.contains(index) else { return }
        subscriptions.remove(at: index)
        saveSubscriptions()
    }
    
    /// 删除订阅（通过 ID）
    func removeSubscription(id: UUID) {
        subscriptions.removeAll { $0.id == id }
        saveSubscriptions()
    }
    
    /// 更新订阅
    func updateSubscription(_ subscription: SourceSubscription) {
        if let index = subscriptions.firstIndex(where: { $0.id == subscription.id }) {
            subscriptions[index] = subscription
            saveSubscriptions()
        }
    }
    
    /// 检查订阅是否需要更新
    func needsUpdate(_ subscription: SourceSubscription) -> Bool {
        guard subscription.autoUpdate else { return false }
        
        guard let lastUpdate = subscription.lastUpdateTime else {
            return true
        }
        
        return Date().timeIntervalSince(lastUpdate) > subscription.updateInterval
    }
    
    /// 更新单个订阅
    func updateSubscription(id: UUID) async throws {
        guard let subscription = subscriptions.first(where: { $0.id == id }) else {
            throw SubscriptionError.subscriptionNotFound
        }

        isUpdating = true
        updateProgress = 0
        lastUpdateError = nil

        defer {
            isUpdating = false
            updateStage = nil
        }

        do {
            try await updateFromSubscription(subscription) { [weak self] stage, fraction in
                Task { @MainActor in
                    self?.updateStage = stage
                    self?.updateProgress = fraction
                }
            }
        } catch {
            lastUpdateError = "\(subscription.name)：\(error.localizedDescription)"
            AppLogger.error("Subscription", "单个订阅更新失败：\(lastUpdateError ?? "")")
            throw error
        }

        updateProgress = 1
    }
    
    /// 更新所有需要更新的订阅
    /// 进度按「订阅 × 阶段」折算：下载 0~15%、解析 15~30%、导入 30~100%
    func updateAllSubscriptions() async {
        guard !isUpdating else { return }

        isUpdating = true
        updateProgress = 0
        lastUpdateError = nil
        updateStage = "准备中"

        let targets = subscriptions.filter { $0.enabled && needsUpdate($0) }

        guard !targets.isEmpty else {
            isUpdating = false
            updateProgress = 1
            updateStage = nil
            lastUpdateError = subscriptions.isEmpty
                ? "还没有订阅，请先添加书源订阅地址"
                : "没有到期的订阅（检查订阅是否启用、更新间隔是否已到）"
            AppLogger.info("Subscription", lastUpdateError ?? "")
            return
        }

        AppLogger.info("Subscription", "开始更新 \(targets.count) 个订阅")

        var failures: [String] = []
        let total = Double(targets.count)

        for (index, subscription) in targets.enumerated() {
            do {
                try await updateFromSubscription(subscription) { [weak self] stage, fraction in
                    Task { @MainActor in
                        self?.updateStage = stage
                        self?.updateProgress = (Double(index) + fraction) / total
                    }
                }
            } catch {
                let message = "\(subscription.name)：\(error.localizedDescription)"
                failures.append(message)
                AppLogger.error("Subscription", "订阅更新失败 \(message)")
            }
        }

        isUpdating = false
        updateStage = nil
        updateProgress = 1

        if failures.isEmpty {
            UserDefaults.standard.set(Date(), forKey: lastUpdateKey)
            AppLogger.info("Subscription", "订阅更新完成，共 \(targets.count) 个")
        } else {
            lastUpdateError = failures.joined(separator: "\n")
        }
    }
    
    /// 从订阅 URL 导入书源
    func importFromUrl(_ url: String) async throws -> Int {
        let sources = try await fetchSources(from: url)
        try await importSources(sources)
        return sources.count
    }
    
    /// 导出书源为订阅格式
    func exportSourcesAsSubscription(sources: [BookSource], format: ExportFormat = .json) -> Data? {
        let exportSources = sources.map { ExportableSource(from: $0) }
        
        switch format {
        case .json:
            return try? JSONEncoder().encode(exportSources)
        case .jsonLines:
            let lines = exportSources.compactMap { try? JSONEncoder().encode($0) }
            let combined = lines.map { String(data: $0, encoding: .utf8) ?? "" }.joined(separator: "\n")
            return combined.data(using: .utf8)
        }
    }
    
    // MARK: - 私有方法
    
    private func updateFromSubscription(
        _ subscription: SourceSubscription,
        progress: ((String, Double) -> Void)? = nil
    ) async throws {
        progress("下载 \(subscription.name)", 0.05)

        let sources = try await fetchSources(from: subscription.url)
        progress("解析到 \(sources.count) 个书源", 0.3)

        try await importSources(sources) { done, total in
            let ratio = Double(done) / Double(max(1, total))
            progress("导入 \(done)/\(total)", 0.3 + 0.7 * ratio)
        }

        // 更新订阅的最后更新时间
        if let index = subscriptions.firstIndex(where: { $0.id == subscription.id }) {
            subscriptions[index].lastUpdateTime = Date()
            saveSubscriptions()
        }
    }
    
    private func fetchSources(from urlString: String) async throws -> [ExportableSource] {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            AppLogger.error("Subscription", "订阅地址不合法（只支持 http/https）：\(trimmed.prefix(160))")
            throw SubscriptionError.invalidUrl
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        // 不少订阅托管在 CDN 上，会用 UA 拦默认客户端
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )

        AppLogger.info("Subscription", "请求 \(url.absoluteString)")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            AppLogger.error(
                "Subscription",
                "请求失败 host=\(url.host ?? "-") err=\(error.localizedDescription) code=\((error as NSError).code)"
            )
            throw error
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        AppLogger.info("Subscription", "响应 status=\(status) bytes=\(data.count) host=\(url.host ?? "-")")

        guard (200..<300).contains(status) else {
            AppLogger.error("Subscription", "HTTP \(status)：\(url.absoluteString)")
            throw SubscriptionError.networkError
        }
        
        // 尝试解析为 JSON 数组
        if let sources = try? JSONDecoder().decode([ExportableSource].self, from: data) {
            AppLogger.info("Subscription", "解析成功（JSON 数组）\(sources.count) 个")
            return sources
        }
        
        // 尝试解析为 JSON Lines 格式
        var sources: [ExportableSource] = []
        let lines = String(data: data, encoding: .utf8)?.components(separatedBy: .newlines) ?? []
        
        for line in lines {
            guard !line.isEmpty, let lineData = line.data(using: .utf8) else { continue }
            if let source = try? JSONDecoder().decode(ExportableSource.self, from: lineData) {
                sources.append(source)
            }
        }
        
        if sources.isEmpty {
            // 把响应开头打出来，便于判断是 403 页面、HTML 错误页还是字段不匹配
            let preview = String(data: data.prefix(240), encoding: .utf8) ?? "<非文本>"
            let normalized = preview.replacingOccurrences(of: "\n", with: " ")
            AppLogger.error("Subscription", "解析失败，响应片段：\(normalized)")
            throw SubscriptionError.parseError
        }

        AppLogger.info("Subscription", "解析成功（JSON Lines）\(sources.count) 个")
        return sources
    }
    
    private func importSources(
        _ sources: [ExportableSource],
        progress: ((Int, Int) -> Void)? = nil
    ) async throws {
        guard !sources.isEmpty else { return }

        let context = CoreDataStack.shared.viewContext

        // 一次性预取已有书源，避免「每个源一次全表查询」的 O(n²)
        let allExisting = (try? context.fetch(BookSource.fetchRequest())) ?? []
        var index: [String: BookSource] = [:]
        index.reserveCapacity(allExisting.count)
        for item in allExisting {
            index[item.bookSourceUrl] = item
        }

        AppLogger.info("Subscription", "导入开始 sources=\(sources.count) existing=\(allExisting.count)")

        var processed = 0

        for source in sources {
            if let existing = index[source.bookSourceUrl] {
                // 已存在的源保留本地启停状态
                updateBookSource(existing, with: source, preserveLocalState: true)
            } else {
                let created = BookSource.create(in: context)
                updateBookSource(created, with: source, preserveLocalState: false)
                index[source.bookSourceUrl] = created
            }

            processed += 1
            progress?(processed, sources.count)

            // 每 50 个存一次并让出主线程，保证进度条能刷新、界面不卡
            if processed % 50 == 0 {
                try? context.save()
                await Task.yield()
            }
        }

        try context.save()
        AppLogger.info("Subscription", "导入完成 \(processed) 个")
    }
    
    /// 把订阅里的源写入实体
    /// - Parameter preserveLocalState: true 时保留本地的启停状态（更新已有源时用，
    ///   避免订阅更新把你手动停用的源重新启用）
    private func updateBookSource(
        _ bookSource: BookSource,
        with source: ExportableSource,
        preserveLocalState: Bool = false
    ) {
        bookSource.bookSourceUrl = source.bookSourceUrl
        bookSource.bookSourceName = source.bookSourceName
        bookSource.bookSourceGroup = source.bookSourceGroup
        bookSource.bookSourceType = Int32(source.bookSourceType ?? 0)
        bookSource.bookUrlPattern = source.bookUrlPattern
        bookSource.header = source.header
        bookSource.concurrentRate = source.concurrentRate
        bookSource.loginUrl = source.loginUrl
        bookSource.loginUi = source.loginUi
        bookSource.loginCheckJs = source.loginCheckJs
        bookSource.jsLib = source.jsLib
        bookSource.coverDecodeJs = source.coverDecodeJs
        bookSource.variableComment = source.variableComment
        bookSource.bookSourceComment = source.bookSourceComment
        bookSource.enabledCookieJar = source.enabledCookieJar ?? false
        bookSource.searchUrl = source.searchUrl
        bookSource.exploreUrl = source.exploreUrl
        bookSource.weight = Int32(source.weight ?? 0)
        bookSource.customOrder = Int32(source.customOrder ?? Int(bookSource.customOrder))
        bookSource.lastUpdateTime = Int64(Date().timeIntervalSince1970)

        if !preserveLocalState {
            bookSource.enabled = source.enabled ?? true
            bookSource.enabledExplore = source.enabledExplore ?? true
            bookSource.respondTime = Int64(source.respondTime ?? 0)
        }

        if let ruleReview = source.ruleReview, !ruleReview.isEmpty {
            bookSource.ruleReviewData = ruleReview.data(using: .utf8)
        }
        
        // 规则数据
        if let searchRule = source.ruleSearch {
            bookSource.ruleSearchData = try? JSONEncoder().encode(searchRule)
        }
        
        if let exploreRule = source.ruleExplore {
            bookSource.ruleExploreData = try? JSONEncoder().encode(exploreRule)
        }
        
        if let bookInfoRule = source.ruleBookInfo {
            bookSource.ruleBookInfoData = try? JSONEncoder().encode(bookInfoRule)
        }
        
        if let tocRule = source.ruleToc {
            bookSource.ruleTocData = try? JSONEncoder().encode(tocRule)
        }
        
        if let contentRule = source.ruleContent {
            bookSource.ruleContentData = try? JSONEncoder().encode(contentRule)
        }
    }
    
    private func loadSubscriptions() {
        guard let data = UserDefaults.standard.data(forKey: subscriptionsKey),
              let decoded = try? JSONDecoder().decode([SourceSubscription].self, from: data) else {
            subscriptions = []
            return
        }
        subscriptions = decoded
    }
    
    private func saveSubscriptions() {
        guard let data = try? JSONEncoder().encode(subscriptions) else { return }
        UserDefaults.standard.set(data, forKey: subscriptionsKey)
    }
}

// MARK: - 可导出书源

struct ExportableSource: Codable {
    let bookSourceUrl: String
    let bookSourceName: String
    var bookSourceGroup: String?
    var bookSourceType: Int?
    var bookUrlPattern: String?
    var header: String?
    var concurrentRate: String?
    var loginUrl: String?
    var loginUi: String?
    var loginCheckJs: String?
    var jsLib: String?
    var coverDecodeJs: String?
    var variableComment: String?
    var bookSourceComment: String?
    var enabledCookieJar: Bool?
    var searchUrl: String?
    var exploreUrl: String?
    var enabled: Bool?
    var enabledExplore: Bool?
    var weight: Int?
    var customOrder: Int?
    var respondTime: Int?
    var lastUpdateTime: Int?
    var ruleReview: String?
    
    var ruleSearch: BookSource.SearchRule?
    var ruleExplore: BookSource.ExploreRule?
    var ruleBookInfo: BookSource.BookInfoRule?
    var ruleToc: BookSource.TocRule?
    var ruleContent: BookSource.ContentRule?
    
    init(from source: BookSource) {
        self.bookSourceUrl = source.bookSourceUrl
        self.bookSourceName = source.bookSourceName
        self.bookSourceGroup = source.bookSourceGroup
        self.bookSourceType = Int(source.bookSourceType)
        self.bookUrlPattern = source.bookUrlPattern
        self.header = source.header
        self.concurrentRate = source.concurrentRate
        self.loginUrl = source.loginUrl
        self.loginUi = source.loginUi
        self.loginCheckJs = source.loginCheckJs
        self.jsLib = source.jsLib
        self.coverDecodeJs = source.coverDecodeJs
        self.variableComment = source.variableComment
        self.bookSourceComment = source.bookSourceComment
        self.enabledCookieJar = source.enabledCookieJar
        self.searchUrl = source.searchUrl
        self.exploreUrl = source.exploreUrl
        self.enabled = source.enabled
        self.enabledExplore = source.enabledExplore
        self.weight = Int(source.weight)
        self.customOrder = Int(source.customOrder)
        self.respondTime = Int(source.respondTime)
        self.lastUpdateTime = Int(source.lastUpdateTime)
        self.ruleReview = source.ruleReviewData.flatMap { String(data: $0, encoding: .utf8) }
        
        self.ruleSearch = try? source.ruleSearchData.flatMap { try JSONDecoder().decode(BookSource.SearchRule.self, from: $0) }
        self.ruleExplore = try? source.ruleExploreData.flatMap { try JSONDecoder().decode(BookSource.ExploreRule.self, from: $0) }
        self.ruleBookInfo = try? source.ruleBookInfoData.flatMap { try JSONDecoder().decode(BookSource.BookInfoRule.self, from: $0) }
        self.ruleToc = try? source.ruleTocData.flatMap { try JSONDecoder().decode(BookSource.TocRule.self, from: $0) }
        self.ruleContent = try? source.ruleContentData.flatMap { try JSONDecoder().decode(BookSource.ContentRule.self, from: $0) }
    }
}

// MARK: - 导出格式

enum ExportFormat {
    case json
    case jsonLines
}

// MARK: - 错误类型

enum SubscriptionError: LocalizedError {
    case invalidUrl
    case networkError
    case parseError
    case subscriptionNotFound
    
    var errorDescription: String? {
        switch self {
        case .invalidUrl: return "无效的订阅 URL"
        case .networkError: return "网络请求失败"
        case .parseError: return "解析书源失败"
        case .subscriptionNotFound: return "订阅不存在"
        }
    }
}