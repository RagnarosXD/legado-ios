//
//  ImageCacheManager.swift
//  Legado-iOS
//
//  图片缓存管理器
//

import UIKit
import SwiftUI


/// 图片缓存管理器
class ImageCacheManager: ObservableObject {
    static let shared = ImageCacheManager()
    
    // 内存缓存
    private let memoryCache = NSCache<NSString, UIImage>()
    
    // 磁盘缓存
    private let fileManager = FileManager.default
    private let cacheDirectory: URL
    
    // 配置
    var maxMemoryCost = 100 * 1024 * 1024  // 100MB
    var maxDiskSize = 500 * 1024 * 1024    // 500MB
    
    init() {
        memoryCache.countLimit = 100
        memoryCache.totalCostLimit = maxMemoryCost
        
        let paths = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)
        cacheDirectory = paths[0].appendingPathComponent("images", isDirectory: true)
        
        if !fileManager.fileExists(atPath: cacheDirectory.path) {
            try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        }
    }
    
    // MARK: - 加载图片
    
    func loadImage(from url: String, completion: @escaping (UIImage?) -> Void) {
        let cacheKey = url.md5() as NSString
        
        // 1. 检查内存缓存
        if let cachedImage = memoryCache.object(forKey: cacheKey) {
            completion(cachedImage)
            return
        }
        
        // 2. 检查磁盘缓存
        if let diskImage = loadFromDisk(url: url) {
            memoryCache.setObject(diskImage, forKey: cacheKey, cost: imageCost(diskImage))
            completion(diskImage)
            return
        }
        
        // 3. 网络加载
        downloadImage(from: url) { [weak self] image in
            guard let self = self, let image = image else {
                completion(nil)
                return
            }
            
            self.memoryCache.setObject(image, forKey: cacheKey, cost: self.imageCost(image))
            self.saveToDisk(image: image, url: url)
            
            completion(image)
        }
    }
    
    // 异步加载（SwiftUI 友好）
    @MainActor
    func loadImage(from url: String) async -> UIImage? {
        await withCheckedContinuation { continuation in
            loadImage(from: url) { image in
                continuation.resume(returning: image)
            }
        }
    }
    
    // MARK: - 下载图片
    
    private func downloadImage(from url: String, completion: @escaping (UIImage?) -> Void) {
        guard let imageURL = Self.makeURL(from: url) else {
            AppLogger.warn("Cover", "封面地址无法解析：\(url.prefix(120))")
            completion(nil)
            return
        }
        
        URLSession.shared.dataTask(with: imageURL) { data, response, error in
            guard let data = data, let image = UIImage(data: data) else {
                completion(nil)
                return
            }
            
            DispatchQueue.main.async {
                completion(image)
            }
        }.resume()
    }
    
    // MARK: - 磁盘缓存
    
    private func loadFromDisk(url: String) -> UIImage? {
        let filePath = cachePath(for: url)
        return UIImage(contentsOfFile: filePath)
    }
    
    private func saveToDisk(image: UIImage, url: String) {
        let filePath = cachePath(for: url)
        guard let data = image.jpegData(compressionQuality: 0.8) else { return }
        try? data.write(to: URL(fileURLWithPath: filePath))
        checkDiskSize()
    }
    
    /// 兼容未编码的中文/空格文件名（很多站点封面是中文路径）
    private static func makeURL(from string: String) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), url.scheme != nil {
            return url
        }
        guard let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return nil
        }
        return URL(string: encoded)
    }

    private func cachePath(for url: String) -> String {
        let fileName = url.md5()
        return cacheDirectory.appendingPathComponent(fileName).path
    }
    
    // MARK: - 缓存清理
    
    func clearCache() {
        memoryCache.removeAllObjects()
        try? fileManager.removeItem(at: cacheDirectory)
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }
    
    private func checkDiskSize() {
        let size = getDiskSize()
        if size > maxDiskSize {
            clearOldCache()
        }
    }
    
    private func getDiskSize() -> Int64 {
        var totalSize: Int64 = 0
        if let enumerator = fileManager.enumerator(at: cacheDirectory, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let fileURL as URL in enumerator {
                if let fileSize = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    totalSize += Int64(fileSize)
                }
            }
        }
        return totalSize
    }
    
    private func clearOldCache() {
        guard let files = try? fileManager.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        
        let sorted = files.sorted { url1, url2 in
            let date1 = try? url1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            let date2 = try? url2.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            return date1 ?? .distantPast < date2 ?? .distantPast
        }
        
        let deleteCount = max(1, files.count / 5)
        for file in sorted.prefix(deleteCount) {
            try? fileManager.removeItem(at: file)
        }
    }
    
    private func imageCost(_ image: UIImage) -> Int {
        Int(image.size.height * image.size.width * image.scale * 4)
    }
}

// MARK: - String 扩展（MD5）
import CryptoKit

extension String {
    func md5() -> String {
        let data = Data(utf8)
        let digest = Insecure.MD5.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
