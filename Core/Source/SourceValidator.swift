//
//  SourceValidator.swift
//  Legado-iOS
//
//  书源校验（对标 Android 版「校验书源」）
//  - 文本源：用 checkKeyWord（缺省「我的」）跑一次真实搜索，能解析出结果即视为可用
//  - 有声/漫画源：本版本不参与阅读，只校验站点是否可达
//  - 结果记录耗时，可回写 respondTime
//

import Foundation

struct SourceCheckOutcome: Identifiable {
    let sourceId: UUID
    let name: String
    let typeName: String
    let success: Bool
    let cost: Int
    let message: String

    var id: UUID { sourceId }
}

enum SourceValidator {

    /// 默认校验关键词，对应 Android 的 checkKeyWord 缺省值
    static let defaultKeyWord = "我的"

    /// 全流程在主线程执行：Core Data 对象不能跨线程访问，网络 await 时主线程会释放
    @MainActor
    static func check(source: BookSource) async -> SourceCheckOutcome {
        let startedAt = Date()
        let name = source.bookSourceName
        let typeName = source.typeDisplayName

        // 非文本源：只测站点可达
        guard source.supportsTextSearch else {
            let reachable = await checkReachability(urlString: source.bookSourceUrl)
            let cost = elapsed(from: startedAt)
            return SourceCheckOutcome(
                sourceId: source.sourceId,
                name: name,
                typeName: typeName,
                success: reachable,
                cost: cost,
                message: reachable ? "站点可访问（本版本不支持该类型阅读）" : "站点无法访问"
            )
        }

        guard let searchUrl = source.searchUrl, !searchUrl.isEmpty else {
            return SourceCheckOutcome(
                sourceId: source.sourceId,
                name: name,
                typeName: typeName,
                success: false,
                cost: elapsed(from: startedAt),
                message: "未配置搜索地址"
            )
        }

        let keyWord = source.getSearchRule()?.checkKeyWord?.trimmingCharacters(in: .whitespacesAndNewlines)
        let keyword = (keyWord?.isEmpty == false ? keyWord : nil) ?? defaultKeyWord

        do {
            let books = try await WebBook.searchBook(source: source, key: keyword)
            let cost = elapsed(from: startedAt)
            if books.isEmpty {
                return SourceCheckOutcome(
                    sourceId: source.sourceId,
                    name: name,
                    typeName: typeName,
                    success: false,
                    cost: cost,
                    message: "「\(keyword)」没有解析到结果"
                )
            }
            source.respondTime = Int64(cost)
            AppLogger.info("Validate", "\(name) 可用，\(books.count) 条，耗时 \(cost)ms")
            return SourceCheckOutcome(
                sourceId: source.sourceId,
                name: name,
                typeName: typeName,
                success: true,
                cost: cost,
                message: "\(books.count) 条结果"
            )
        } catch {
            let cost = elapsed(from: startedAt)
            AppLogger.warn("Validate", "\(name) 校验失败：\(error)")
            return SourceCheckOutcome(
                sourceId: source.sourceId,
                name: name,
                typeName: typeName,
                success: false,
                cost: cost,
                message: shortMessage(for: error)
            )
        }
    }

    // MARK: - 辅助

    private static func checkReachability(urlString: String) async -> Bool {
        guard let url = URL(string: urlString) else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200..<400).contains(http.statusCode)
        } catch {
            return false
        }
    }

    private static func elapsed(from date: Date) -> Int {
        Int(Date().timeIntervalSince(date) * 1000)
    }

    private static func shortMessage(for error: Error) -> String {
        if let webError = error as? WebBookError {
            return webError.errorDescription ?? "解析失败"
        }
        let nsError = error as NSError
        switch nsError.code {
        case NSURLErrorTimedOut:
            return "请求超时"
        case NSURLErrorNotConnectedToInternet:
            return "无网络"
        case NSURLErrorAppTransportSecurityRequiresSecureConnection:
            return "被 ATS 拦截（http 源）"
        default:
            return nsError.localizedDescription
        }
    }
}
