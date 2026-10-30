//
//  SearchSourceCache.swift
//  Legado-iOS
//
//  搜索命中缓存：把「某本书在哪些书源里出现过」记下来，
//  换源时先给上次的候选，避免每次都全量搜索 700+ 个源。
//

import Foundation

struct CachedSourceHit: Codable, Identifiable {
    var sourceId: UUID
    var sourceName: String
    var sourceUrl: String
    var bookUrl: String
    var coverUrl: String?
    var intro: String?
    var cachedAt: Date

    var id: UUID { sourceId }

    var ageDescription: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .short
        return formatter.localizedString(for: cachedAt, relativeTo: Date())
    }
}

final class SearchSourceCache {

    static let shared = SearchSourceCache()

    private let queue = DispatchQueue(label: "com.legado.searchcache")
    private let maxBooks = 200
    private let maxAgeDays = 30

    private var storage: [String: [CachedSourceHit]] = [:]
    private var loaded = false

    private var fileURL: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("search-source-cache.json")
    }

    // MARK: - 键

    /// 与搜索结果聚合一致的键：书名 + 作者
    static func key(name: String, author: String) -> String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAuthor = author.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(trimmedName)|\(trimmedAuthor)"
    }

    // MARK: - 读写

    func hits(name: String, author: String) -> [CachedSourceHit] {
        queue.sync {
            loadIfNeeded()
            let key = Self.key(name: name, author: author)
            if let exact = storage[key] {
                return exact.sorted { $0.cachedAt > $1.cachedAt }
            }

            // 作者可能为空或写法不同，退化为按书名匹配
            let namePrefix = name.trimmingCharacters(in: .whitespacesAndNewlines) + "|"
            let fuzzy = storage
                .filter { $0.key.hasPrefix(namePrefix) }
                .flatMap { $0.value }
                .sorted { $0.cachedAt > $1.cachedAt }
            return fuzzy
        }
    }

    func save(name: String, author: String, hits: [CachedSourceHit]) {
        guard !hits.isEmpty else { return }
        queue.async {
            self.loadIfNeeded()
            let key = Self.key(name: name, author: author)

            var merged = self.storage[key] ?? []
            for hit in hits {
                merged.removeAll { $0.sourceId == hit.sourceId }
                merged.append(hit)
            }

            self.storage[key] = merged
            self.prune()
            self.persist()
            AppLogger.info("Cache", "缓存换源候选 \(key) 候选=\(merged.count)")
        }
    }

    func clear() {
        queue.async {
            self.storage = [:]
            self.persist()
            AppLogger.info("Cache", "已清空换源缓存")
        }
    }

    var bookCount: Int {
        queue.sync {
            loadIfNeeded()
            return storage.count
        }
    }

    // MARK: - 内部

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: [CachedSourceHit]].self, from: data) else {
            return
        }
        storage = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(storage) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func prune() {
        let deadline = Calendar.current.date(byAdding: .day, value: -maxAgeDays, to: Date()) ?? Date()

        for (key, hits) in storage {
            let fresh = hits.filter { $0.cachedAt > deadline }
            if fresh.isEmpty {
                storage.removeValue(forKey: key)
            } else {
                storage[key] = fresh
            }
        }

        if storage.count > maxBooks {
            let ordered = storage.sorted { lhs, rhs in
                let left = lhs.value.map(\.cachedAt).max() ?? .distantPast
                let right = rhs.value.map(\.cachedAt).max() ?? .distantPast
                return left > right
            }
            storage = Dictionary(ordered.prefix(maxBooks), uniquingKeysWith: { first, _ in first })
        }
    }
}
