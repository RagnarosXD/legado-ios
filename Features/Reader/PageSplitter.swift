//
//  PageSplitter.swift
//  Legado-iOS
//
//  基于 CoreText 的文本分页引擎
//  将长文本精确分割为屏幕大小的页面
//

import Foundation
import CoreText
import UIKit

// MARK: - 分页配置

/// 排版参数，字段与 Android ReadBookConfig.Config 一一对应
/// 参见 `ReadBookConfig.kt:907-989`、`ChapterProvider.kt:304-329`、`TextChapterLayout.kt:1120-1357`
struct PageConfig: @unchecked Sendable {
    /// 正文字号（Android textSize，默认 20sp）
    var fontSize: CGFloat = 20
    /// Android lineSpacingExtra：整数，除以 10 得到「行高倍数增量」（默认 12 → 行高 1.2 倍）
    var lineSpacingExtra: CGFloat = 12
    /// Android paragraphSpacing：整数，除以 10 后乘以行高（默认 2 → 0.2 倍行高）
    var paragraphSpacingExtra: CGFloat = 2
    /// Android letterSpacing：em 倍数（默认 0.1）
    var letterSpacingEm: CGFloat = 0.1
    /// 首行缩进字符数（Android 用两个全角空格 "　　"）
    var firstLineIndentChars: CGFloat = 2
    /// 两端对齐（Android textFullJustify 默认 true）
    var justified: Bool = true
    var textColor: UIColor = UIColor(red: 0x3E / 255, green: 0x3D / 255, blue: 0x3B / 255, alpha: 1)
    /// 页面边距（Android paddingTop/Bottom 6dp、Left/Right 16dp）
    var margins: UIEdgeInsets = UIEdgeInsets(top: 6, left: 16, bottom: 6, right: 16)
    /// 章节标题（Android titleMode：nil 表示隐藏）
    var titleText: String?
    /// 标题字号增量（Android titleSize，默认 0）
    var titleSizeDelta: CGFloat = 0
    /// 标题对齐（Android titleMode 0=居左 1=居中）
    var titleAlignment: NSTextAlignment = .left
    /// 页眉占用高度（0 = 不显示，对齐 Android headerPadding）
    var headerHeight: CGFloat = 0
    /// 页脚占用高度（0 = 不显示，对齐 Android footerPadding）
    var footerHeight: CGFloat = 0
    var containerSize: CGSize
    var font: UIFont

    /// 字体自身行高（ascent + descent + leading），对应 Android `fontMetrics.descent - ascent + leading`
    var fontLineHeight: CGFloat {
        max(1, font.lineHeight)
    }

    /// 实际行高 = 字体行高 × (1 + lineSpacingExtra/10)
    var lineHeight: CGFloat {
        fontLineHeight * (1 + max(0, lineSpacingExtra) / 10)
    }

    /// CoreText 需要的额外行距（在字体行高之外补的差值）
    var coreTextLineSpacing: CGFloat {
        max(0, lineHeight - fontLineHeight)
    }

    /// 段间距 = 行高 × paragraphSpacingExtra/10
    var paragraphSpacing: CGFloat {
        lineHeight * max(0, paragraphSpacingExtra) / 10
    }

    /// 首行缩进 = 两个全角空格的实测宽度（Android `measureText(paragraphIndent)`）
    var firstLineIndent: CGFloat {
        guard firstLineIndentChars > 0 else { return 0 }
        let width = ("\u{3000}" as NSString).size(withAttributes: [.font: font]).width
        return width * firstLineIndentChars
    }

    /// 字距 = letterSpacingEm × fontSize
    var kern: CGFloat {
        letterSpacingEm * fontSize
    }

    /// 实际可用于排版的区域大小
    var contentSize: CGSize {
        CGSize(
            width: containerSize.width - margins.left - margins.right,
            height: containerSize.height - margins.top - margins.bottom - headerHeight - footerHeight
        )
    }

    /// 便捷构造：用系统字体
    static func `default`(containerSize: CGSize) -> PageConfig {
        let font = UIFont.systemFont(ofSize: 20)
        return PageConfig(containerSize: containerSize, font: font)
    }

    /// 从 ReaderViewModel 设置构造
    static func from(
        fontSize: CGFloat,
        lineSpacingExtra: CGFloat = 12,
        paragraphSpacingExtra: CGFloat = 2,
        letterSpacingEm: CGFloat = 0.1,
        firstLineIndentChars: CGFloat = 2,
        justified: Bool = true,
        padding: UIEdgeInsets,
        containerSize: CGSize,
        fontFamily: String? = nil
    ) -> PageConfig {
        let font: UIFont
        if let family = fontFamily, !family.isEmpty, family != "System" {
            font = UIFont(name: family, size: fontSize) ?? UIFont.systemFont(ofSize: fontSize)
        } else {
            font = UIFont.systemFont(ofSize: fontSize)
        }
        return PageConfig(
            fontSize: fontSize,
            lineSpacingExtra: lineSpacingExtra,
            paragraphSpacingExtra: paragraphSpacingExtra,
            letterSpacingEm: letterSpacingEm,
            firstLineIndentChars: firstLineIndentChars,
            justified: justified,
            margins: padding,
            containerSize: containerSize,
            font: font
        )
    }
}

// MARK: - 分页结果

struct PageSplitResult {
    /// 每页的文本内容
    let pages: [String]
    /// 每页对应原文的 Range
    let pageRanges: [Range<String.Index>]
    /// 总页数
    var totalPages: Int { pages.count }
}

// MARK: - PageSplitter

final class PageSplitter {
    
    // MARK: - 公开接口
    
    /// 将文本分割为多页
    /// - Parameters:
    ///   - text: 原始文本
    ///   - config: 分页配置
    /// - Returns: 分页后的文本数组
    static func split(text: String, config: PageConfig) -> [String] {
        let result = splitWithRanges(text: text, config: config)
        return result.pages
    }
    
    /// 只分前 `limit` 页（首屏优先：长章节也能立刻出字）
    static func splitFirstPages(text: String, config: PageConfig, limit: Int = 1) -> [String] {
        guard limit > 0 else { return [] }
        return splitWithRanges(text: text, config: config, pageLimit: limit).pages
    }

    /// 将文本分割为多页，同时返回每页对应的原文范围
    /// - Parameter pageLimit: 大于 0 时最多产出这么多页（默认全量）
    static func splitWithRanges(
        text: String,
        config: PageConfig,
        pageLimit: Int = 0
    ) -> PageSplitResult {
        guard !text.isEmpty else {
            return PageSplitResult(pages: [], pageRanges: [])
        }
        
        let contentSize = config.contentSize
        guard contentSize.width > 0, contentSize.height > 0 else {
            return PageSplitResult(pages: [text], pageRanges: [text.startIndex..<text.endIndex])
        }
        
        // 构建 NSAttributedString
        let attributedString = buildAttributedString(text: text, config: config)
        
        // 使用 CTFramesetter 进行分页
        let framesetter = CTFramesetterCreateWithAttributedString(attributedString)
        let path = CGPath(rect: CGRect(origin: .zero, size: contentSize), transform: nil)
        
        var pages: [String] = []
        var pageRanges: [Range<String.Index>] = []
        var currentIndex: CFIndex = 0
        let totalLength = attributedString.length
        
        while currentIndex < totalLength {
            // 首屏优先：达到上限就停，剩余文本交给后台全量分页
            if pageLimit > 0, pages.count >= pageLimit {
                break
            }

            // 计算当前页能容纳的文本范围
            let frameRange = CTFramesetterSuggestFrameSizeWithConstraints(
                framesetter,
                CFRangeMake(currentIndex, 0),
                nil,
                contentSize,
                nil
            )
            _ = frameRange // 仅用于触发计算
            
            // 创建 CTFrame 获取精确范围
            let frame = CTFramesetterCreateFrame(
                framesetter,
                CFRangeMake(currentIndex, 0),
                path,
                nil
            )
            
            let frameVisibleRange = CTFrameGetVisibleStringRange(frame)
            
            // 安全检查：如果没有可见范围，说明剩余文本太少或排版异常
            if frameVisibleRange.length <= 0 {
                // 将剩余文本作为最后一页
                let nsString = attributedString.string as NSString
                let remaining = nsString.substring(from: currentIndex)
                if !remaining.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    pages.append(remaining)
                    let startIdx = text.index(text.startIndex, offsetBy: currentIndex, limitedBy: text.endIndex) ?? text.endIndex
                    pageRanges.append(startIdx..<text.endIndex)
                }
                break
            }
            
            // 提取当前页文本
            let nsString = attributedString.string as NSString
            let pageLength = frameVisibleRange.length
            let pageText = nsString.substring(with: NSRange(location: currentIndex, length: pageLength))
            
            // 记录页面
            if !pageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                pages.append(pageText)
                
                let startIdx = text.index(text.startIndex, offsetBy: currentIndex, limitedBy: text.endIndex) ?? text.endIndex
                let endOffset = currentIndex + pageLength
                let endIdx = text.index(text.startIndex, offsetBy: endOffset, limitedBy: text.endIndex) ?? text.endIndex
                pageRanges.append(startIdx..<endIdx)
            }
            
            currentIndex += pageLength
        }
        
        // 保证至少有一页
        if pages.isEmpty {
            pages.append(text)
            pageRanges.append(text.startIndex..<text.endIndex)
        }
        
        return PageSplitResult(pages: pages, pageRanges: pageRanges)
    }
    
    /// 获取指定页的原文范围
    static func pageRange(
        text: String,
        pageIndex: Int,
        config: PageConfig
    ) -> Range<String.Index>? {
        let result = splitWithRanges(text: text, config: config)
        guard pageIndex >= 0, pageIndex < result.pageRanges.count else { return nil }
        return result.pageRanges[pageIndex]
    }
    
    // MARK: - 内部实现
    
    /// 构建带排版属性的 NSAttributedString
    /// 分页与渲染共用这一份属性，避免「算出来的页」和「画出来的页」不一致
    static func attributedText(text: String, config: PageConfig) -> NSAttributedString {
        let paragraphStyle = NSMutableParagraphStyle()
        // Android：行高 = 字体行高 × (1 + lineSpacingExtra/10)，这里用额外行距补足差值
        paragraphStyle.lineSpacing = config.coreTextLineSpacing
        // Android：段距 = 行高 × paragraphSpacing/10
        paragraphStyle.paragraphSpacing = config.paragraphSpacing
        paragraphStyle.alignment = config.justified ? .justified : .natural
        paragraphStyle.lineBreakMode = .byWordWrapping
        // 中文用 pushOut：允许标点挤压，避免行尾大量留白或标点跑到行首
        paragraphStyle.lineBreakStrategy = .pushOut

        // 首行缩进：两个全角空格的实际宽度（与 Android 插入 "　　" 等价）
        paragraphStyle.firstLineHeadIndent = config.firstLineIndent
        paragraphStyle.headIndent = 0

        var attributes: [NSAttributedString.Key: Any] = [
            .font: config.font,
            .paragraphStyle: paragraphStyle,
            .foregroundColor: config.textColor
        ]
        // Android letterSpacing 是 em 倍数，转换为 pt
        if config.kern != 0 {
            attributes[.kern] = config.kern
        }

        let body = NSAttributedString(string: normalizeText(text), attributes: attributes)

        // 章节标题（Android titleMode / titleSize）：作为正文第一段，字号更大、可居中
        guard let title = config.titleText, !title.isEmpty else { return body }

        let titleStyle = NSMutableParagraphStyle()
        titleStyle.alignment = config.titleAlignment
        titleStyle.paragraphSpacing = config.paragraphSpacing
        titleStyle.lineBreakMode = .byWordWrapping

        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.boldSystemFont(ofSize: config.fontSize + config.titleSizeDelta),
            .paragraphStyle: titleStyle,
            .foregroundColor: config.textColor
        ]

        let result = NSMutableAttributedString()
        result.append(NSAttributedString(string: title + "\n", attributes: titleAttributes))
        result.append(body)
        return result
    }

    /// 兼容旧调用
    private static func buildAttributedString(text: String, config: PageConfig) -> NSAttributedString {
        attributedText(text: text, config: config)
    }
    
    /// 规范化文本，统一换行符并处理 CJK 排版
    private static func normalizeText(_ text: String) -> String {
        var result = text
        // 统一换行符
        result = result.replacingOccurrences(of: "\r\n", with: "\n")
        result = result.replacingOccurrences(of: "\r", with: "\n")
        
        // 移除首尾多余空白
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // 连续空行压缩为单个空行
        while result.contains("\n\n\n") {
            result = result.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        
        return result
    }
}

// MARK: - 分页缓存

final class PageSplitCache: @unchecked Sendable {
    static let shared = PageSplitCache()
    
    private struct CacheKey: Hashable {
        let textHash: Int
        let configHash: Int
    }
    
    private var cache: [CacheKey: PageSplitResult] = [:]
    private let queue = DispatchQueue(label: "com.legado.pagesplit.cache", attributes: .concurrent)
    private let maxCacheCount = 10
    
    private init() {}
    
    /// 获取缓存的分页结果，若无缓存则计算并缓存
    func getOrSplit(text: String, config: PageConfig) -> PageSplitResult {
        let key = CacheKey(
            textHash: text.hashValue,
            configHash: configHashValue(config)
        )
        
        // 读缓存
        var cached: PageSplitResult?
        queue.sync {
            cached = cache[key]
        }
        if let result = cached {
            return result
        }
        
        // 计算分页
        let result = PageSplitter.splitWithRanges(text: text, config: config)
        
        // 写缓存
        queue.async(flags: .barrier) { [weak self] in
            guard let self else { return }
            // LRU 简单策略：超出上限时清空
            if self.cache.count >= self.maxCacheCount {
                self.cache.removeAll()
            }
            self.cache[key] = result
        }
        
        return result
    }
    
    /// 清除所有缓存（配置变更时调用）
    func invalidate() {
        queue.async(flags: .barrier) { [weak self] in
            self?.cache.removeAll()
        }
    }
    
    private func configHashValue(_ config: PageConfig) -> Int {
        var hasher = Hasher()
        hasher.combine(config.fontSize)
        hasher.combine(config.lineSpacingExtra)
        hasher.combine(config.paragraphSpacingExtra)
        hasher.combine(config.letterSpacingEm)
        hasher.combine(config.firstLineIndentChars)
        hasher.combine(config.justified)
        hasher.combine(config.titleText ?? "")
        hasher.combine(config.titleSizeDelta)
        hasher.combine(config.titleAlignment.rawValue)
        hasher.combine(config.headerHeight)
        hasher.combine(config.footerHeight)
        hasher.combine(config.margins.top)
        hasher.combine(config.margins.left)
        hasher.combine(config.margins.bottom)
        hasher.combine(config.margins.right)
        hasher.combine(config.containerSize.width)
        hasher.combine(config.containerSize.height)
        hasher.combine(config.font.fontName)
        return hasher.finalize()
    }
}
