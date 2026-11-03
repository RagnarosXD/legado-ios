//
//  ReaderViewModel.swift
//  Legado-iOS
//
//  阅读器 ViewModel
//

import Foundation
import SwiftUI
import UIKit
import CoreData

@MainActor
class ReaderViewModel: ObservableObject {
    // MARK: - Published 属性
    @Published var chapterContent: String?
    /// 图片章节（CBZ 漫画）的图片列表，非空时阅读器走图片模式
    @Published var chapterImages: [URL] = []
    @Published var currentChapter: BookChapter?
    @Published var currentChapterIndex: Int = 0
    @Published var totalChapters: Int = 0
    @Published var chapters: [BookChapter] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var currentBook: Book?
    @Published var durChapterPos: Int32 = 0
    @Published var theme: ReaderTheme = .light
    @Published var useReplaceRule: Bool = true
    
    // MARK: - 分页状态
    @Published var currentPageIndex: Int = 0 {
        didSet {
            if oldValue != currentPageIndex {
                updatePagingProgressIfNeeded()
            }
        }
    }
    @Published var totalPages: Int = 0
    
    // MARK: - 阅读设置
    @Published var fontSize: CGFloat = 20 {
        didSet {
            UserDefaults.standard.set(Double(fontSize), forKey: "reader.fontSize")
        }
    }
    @Published var lineSpacing: CGFloat = 12 {
        didSet {
            UserDefaults.standard.set(Double(lineSpacing), forKey: "reader.lineSpacing")
        }
    }
    @Published var pagePadding: EdgeInsets = EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16) {
        didSet {
            UserDefaults.standard.set(Double(pagePadding.leading), forKey: "reader.pageMargin")
        }
    }
    @Published var backgroundColor: Color = .white
    @Published var textColor: Color = .black
    
    // MARK: - 新增阅读设置
    @Published var paragraphSpacing: CGFloat = 2 {
        didSet { UserDefaults.standard.set(Double(paragraphSpacing), forKey: "reader.paragraphSpacing") }
    }
    @Published var letterSpacing: CGFloat = 0.1 {
        didSet { UserDefaults.standard.set(Double(letterSpacing), forKey: "reader.letterSpacing") }
    }
    /// 段首缩进字数（中文习惯 2 字）
    @Published var firstLineIndentChars: CGFloat = 2 {
        didSet { UserDefaults.standard.set(Double(firstLineIndentChars), forKey: "reader.firstLineIndent") }
    }
    /// 行高倍数
    @Published var lineHeightMultiple: CGFloat = 1.0 {
        didSet { UserDefaults.standard.set(Double(lineHeightMultiple), forKey: "reader.lineHeightMultiple") }
    }
    /// 两端对齐
    @Published var textJustified: Bool = true {
        didSet { UserDefaults.standard.set(textJustified, forKey: "reader.justified") }
    }
    /// 字体族（为空用系统字体）
    @Published var fontFamily: String? = nil {
        didSet { UserDefaults.standard.set(fontFamily, forKey: "reader.fontFamily") }
    }
    /// 章节标题显示方式（Android titleMode）：0 居左、1 居中、2 隐藏
    @Published var chapterTitleMode: Int = 0
    /// 标题字号增量（Android titleSize）
    @Published var chapterTitleSizeDelta: CGFloat = 0
    
    // MARK: - 私有属性
    private var ruleEngine: RuleEngine = RuleEngine()
    private var loadTask: Task<Void, Never>?
    let cacheManager = ChapterCacheManager()

    init() {
        loadReaderPreferences()
    }

    private func loadReaderPreferences() {
        let defaults = UserDefaults.standard

        let storedFontSize = defaults.double(forKey: "reader.fontSize")
        if storedFontSize > 0 {
            fontSize = CGFloat(storedFontSize)
        }

        let storedLineSpacing = defaults.double(forKey: "reader.lineSpacing")
        if storedLineSpacing > 0 {
            lineSpacing = CGFloat(storedLineSpacing)
        }

        let storedMargin = defaults.double(forKey: "reader.pageMargin")
        if storedMargin > 0 {
            let margin = CGFloat(storedMargin)
            pagePadding = EdgeInsets(top: 20, leading: margin, bottom: 20, trailing: margin)
        }

        if let storedTheme = defaults.string(forKey: "reader.theme") {
            applyTheme(themeFromStorage(storedTheme))
        }

        // 排版精度设置（0 视为未设置，因为 0 是"无缩进/无字距"的合法值，用 object 判断更准）
        if defaults.object(forKey: "reader.paragraphSpacing") != nil {
            paragraphSpacing = CGFloat(defaults.double(forKey: "reader.paragraphSpacing"))
        }
        if defaults.object(forKey: "reader.letterSpacing") != nil {
            letterSpacing = CGFloat(defaults.double(forKey: "reader.letterSpacing"))
        }
        if defaults.object(forKey: "reader.firstLineIndent") != nil {
            firstLineIndentChars = CGFloat(defaults.double(forKey: "reader.firstLineIndent"))
        }
        if defaults.object(forKey: "reader.lineHeightMultiple") != nil {
            lineHeightMultiple = CGFloat(defaults.double(forKey: "reader.lineHeightMultiple"))
        }
        if defaults.object(forKey: "reader.justified") != nil {
            textJustified = defaults.bool(forKey: "reader.justified")
        }
        if let family = defaults.string(forKey: "reader.fontFamily"), !family.isEmpty {
            fontFamily = family
        }
    }

    /// 供 SwiftUI Text 使用的字体（滚动模式 / 设置预览）
    var readerFont: Font {
        if let family = fontFamily, !family.isEmpty, family != "System" {
            return .custom(family, size: fontSize)
        }
        return .system(size: fontSize)
    }

    /// 滚动模式的额外行距：字体行高 × (lineSpacingExtra/10)，与 Android 行高模型一致
    var effectiveLineSpacing: CGFloat {
        let fontLineHeight = UIFont.systemFont(ofSize: fontSize).lineHeight
        return max(0, fontLineHeight * (lineSpacing / 10))
    }

    /// 当前排版配置（分页与渲染共用）
    /// 真实安全区（灵动岛 / 刘海 / Home 指示条）
    /// SwiftUI 视图一旦 ignoresSafeArea，GeometryReader 里的 safeAreaInsets 会变成 0，
    /// 所以这里直接读 window，保证灵动岛区域一定被避开。
    static var windowSafeArea: UIEdgeInsets {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        return scene?.keyWindow?.safeAreaInsets ?? .zero
    }

    func makePageConfig(
        containerSize: CGSize,
        extraTop: CGFloat = 0,
        extraBottom: CGFloat = 0,
        chapterTitle: String? = nil
    ) -> PageConfig {
        // 灵动岛机型顶部安全区约 59pt、Home 条约 34pt，取两者较大值
        let safeArea = Self.windowSafeArea
        let topInset = max(extraTop, safeArea.top)
        let bottomInset = max(extraBottom, safeArea.bottom)

        var config = PageConfig.from(
            fontSize: fontSize,
            lineSpacingExtra: lineSpacing,
            paragraphSpacingExtra: paragraphSpacing,
            letterSpacingEm: letterSpacing,
            firstLineIndentChars: firstLineIndentChars,
            justified: textJustified,
            padding: UIEdgeInsets(
                top: pagePadding.top + topInset,
                left: pagePadding.leading,
                bottom: pagePadding.bottom + bottomInset,
                right: pagePadding.trailing
            ),
            containerSize: containerSize,
            fontFamily: fontFamily
        )

        // Android titleMode：0 居左、1 居中、2 隐藏
        if chapterTitleMode != 2, let chapterTitle, !chapterTitle.isEmpty {
            config.titleText = chapterTitle
            config.titleAlignment = chapterTitleMode == 1 ? .center : .left
            config.titleSizeDelta = chapterTitleSizeDelta
        }

        return config
    }

    private func themeFromStorage(_ raw: String) -> ReaderTheme {
        switch raw {
        case "暗色":
            return .dark
        case "羊皮纸":
            return .sepia
        case "护眼":
            return .eyeProtection
        default:
            return .light
        }
    }
    
    // MARK: - 颜色主题
    enum ReaderTheme {
        case light
        case dark
        case sepia
        case eyeProtection
        
        var backgroundColor: Color {
            switch self {
            case .light: return Color(red: 0xEE / 255, green: 0xEE / 255, blue: 0xEE / 255)
            case .dark: return Color.black
            case .sepia: return Color(red: 0.96, green: 0.91, blue: 0.83)
            case .eyeProtection: return Color.white
            }
        }
        
        var textColor: Color {
            switch self {
            case .light: return Color(red: 0x3E / 255, green: 0x3D / 255, blue: 0x3B / 255)
            case .dark: return Color(red: 0xAD / 255, green: 0xAD / 255, blue: 0xAD / 255)
            case .sepia: return Color(red: 0.33, green: 0.28, blue: 0.22)
            case .eyeProtection: return Color.black
            }
        }
    }
    
    // MARK: - 加载书籍
    func loadBook(_ book: Book) {
        loadTask?.cancel()
        currentBook = book
        isLoading = true

        loadTask = Task {
            do {
                try Task.checkCancellation()

                applyReadConfig(book)

                // 加载目录
                try await loadChapters(book: book)
                
                // 加载当前章节
                let chapterIndex = Int(book.durChapterIndex)
                if chapterIndex < chapters.count {
                    currentChapterIndex = chapterIndex
                    durChapterPos = book.durChapterPos
                    let restorePage = max(0, Int(book.durChapterPos))
                    try await loadChapter(at: chapterIndex, restorePageIndex: restorePage)
                }
                
                isLoading = false
            } catch is CancellationError {
                isLoading = false
            } catch {
                errorMessage = "加载失败：\(Self.friendlyError(error))"
                isLoading = false
            }
        }
    }
    
    // MARK: - 加载目录
    private func loadChapters(book: Book) async throws {
        let request = BookChapter.fetchRequest(byBookId: book.bookId)
        
        let context = CoreDataStack.shared.viewContext
        var chapters = try context.fetch(request)

        if chapters.isEmpty, !book.isLocal {
            // 关系 / origin(sourceId) / origin(URL) / 源名，逐级尝试，避免单个线索缺失就报「未找到书源」
            guard let source = BookSourceResolver.resolve(for: book, in: context) else {
                AppLogger.error("Reader", "无法解析书源 book=\(book.name) origin=\(book.origin) originName=\(book.originName)")
                throw ReaderError.noSource
            }

            let webChapters = try await WebBook.getChapterList(source: source, book: book)
            guard !webChapters.isEmpty else {
                throw ReaderError.noChapters
            }

            for web in webChapters {
                let chapter = BookChapter.create(
                    in: context,
                    bookId: book.bookId,
                    url: web.url,
                    index: Int32(web.index),
                    title: web.title
                )
                chapter.book = book
                chapter.sourceId = source.sourceId.uuidString
                chapter.isVIP = web.isVip
                chapter.isVolume = web.isVolume
            }

            book.totalChapterNum = Int32(webChapters.count)
            try CoreDataStack.shared.save()

            chapters = try context.fetch(request)
        }

        self.chapters = chapters
        self.totalChapters = chapters.count

        if chapters.isEmpty {
            throw ReaderError.noChapters
        }
    }
    
    // MARK: - 加载章节
    func loadChapter(at index: Int, restorePageIndex: Int? = nil) async throws {
        guard index >= 0 && index < chapters.count else {
            throw ReaderError.invalidChapterIndex
        }
        
        isLoading = true
        currentChapterIndex = index
        currentChapter = chapters[index]
        if let restorePageIndex {
            currentPageIndex = max(0, restorePageIndex)
            durChapterPos = Int32(currentPageIndex)
        } else {
            currentPageIndex = 0
            durChapterPos = 0
        }
        
        do {
            // 尝试从缓存加载
            if let cachedContent = try? await loadCachedChapter(chapters[index]) {
                applyContent(cachedContent, chapter: chapters[index])
                isLoading = false
                return
            }
            
            // 从网络 / 本地文件加载
            let content = try await fetchChapterContent(chapters[index])
            applyContent(content, chapter: chapters[index])
            
            // 缓存章节
            try await cacheChapter(chapters[index], content: content)
            
            isLoading = false
            
            // 预加载前后章节
            if let book = currentBook {
                cacheManager.preloadAroundChapter(
                    index: index,
                    chapters: chapters,
                    book: book
                )
            }
        } catch {
            errorMessage = "加载章节失败：\(error.localizedDescription)"
            isLoading = false
            throw error
        }
    }
    
    // MARK: - 章节导航
    func prevChapter() async {
        guard currentChapterIndex > 0 else { return }
        do {
            try await loadChapter(at: currentChapterIndex - 1)
            saveProgress()
        } catch {
            errorMessage = "加载章节失败：\(error.localizedDescription)"
        }
    }
    
    func nextChapter() async {
        guard currentChapterIndex < totalChapters - 1 else { return }
        do {
            try await loadChapter(at: currentChapterIndex + 1)
            saveProgress()
        } catch {
            errorMessage = "加载章节失败：\(error.localizedDescription)"
        }
    }
    
    func jumpToChapter(_ index: Int) {
        guard index >= 0 && index < totalChapters else { return }
        
        Task {
            try? await loadChapter(at: index)
            saveProgress()
        }
    }

    func loadChapter() async {
        do {
            try await loadChapter(at: currentChapterIndex)
        } catch {
            errorMessage = "加载章节失败：\(error.localizedDescription)"
        }
    }

    func loadChapterList() async {
        guard let book = currentBook else { return }
        do {
            try await loadChapters(book: book)
        } catch {
            errorMessage = "加载目录失败：\(error.localizedDescription)"
        }
    }
    
    // MARK: - 阅读配置
    func applyReadConfig(_ book: Book) {
        let config = book.readConfigObj

        seedGlobalPageAnimationIfNeeded(from: config)

        // 应用主题
        applyTheme(themeFromStorage(UserDefaults.standard.string(forKey: "reader.theme") ?? "亮色"))

        useReplaceRule = config.useReplaceRule
    }

    private func seedGlobalPageAnimationIfNeeded(from config: ReadConfig) {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "pageAnimation") == nil else {
            return
        }
        defaults.set(Self.pageAnimationRawValue(from: config.pageAnim), forKey: "pageAnimation")
    }

    private static func pageAnimationRawValue(from configValue: Int32) -> String {
        let animation = PageAnimation(rawValue: configValue) ?? .cover
        switch animation {
        case .cover:
            return PageAnimationType.cover.rawValue
        case .simulation:
            return PageAnimationType.simulation.rawValue
        case .slide:
            return PageAnimationType.slide.rawValue
        case .scroll:
            return PageAnimationType.scroll.rawValue
        }
    }
    
    func applyTheme(_ theme: ReaderTheme) {
        self.theme = theme
        backgroundColor = theme.backgroundColor
        textColor = theme.textColor

        UserDefaults.standard.set(storageThemeValue(theme), forKey: "reader.theme")
    }

    private func storageThemeValue(_ theme: ReaderTheme) -> String {
        switch theme {
        case .light:
            return "亮色"
        case .dark:
            return "暗色"
        case .sepia:
            return "羊皮纸"
        case .eyeProtection:
            return "护眼"
        }
    }

    private func applyReplaceRulesIfNeeded(_ text: String, chapter: BookChapter) -> String {
        guard let book = currentBook else { return text }
        if !useReplaceRule {
            return text
        }
        return ReplaceEngineEnhanced.shared.applyForReader(
            text: text,
            bookId: book.bookId,
            chapterId: chapter.chapterId,
            context: CoreDataStack.shared.viewContext
        )
    }

    func turnToNextPage() -> Bool {
        guard totalPages > 0 else { return false }
        guard currentPageIndex + 1 < totalPages else { return false }
        currentPageIndex += 1
        return true
    }

    func turnToPreviousPage() -> Bool {
        guard totalPages > 0 else { return false }
        guard currentPageIndex > 0 else { return false }
        currentPageIndex -= 1
        return true
    }

    private func updatePagingProgressIfNeeded() {
        let clamped = max(0, currentPageIndex)
        let newPos = Int32(clamped)
        if durChapterPos != newPos {
            durChapterPos = newPos
        }
        saveProgress()
    }

    func setTheme(_ theme: ReaderTheme) async {
        applyTheme(theme)
    }

    func setFontSize(_ size: CGFloat) async {
        let clamped = min(max(size, 8), 32)
        fontSize = clamped
    }
    
    // MARK: - 缓存管理
    private func loadCachedChapter(_ chapter: BookChapter) async throws -> String {
        // 从文件系统加载缓存的章节内容
        guard chapter.isCached, let cachePath = chapter.cachePath, !cachePath.isEmpty else {
            throw ReaderError.notCached
        }
        
        let cacheURL: URL
        if cachePath.hasPrefix("/") {
            cacheURL = URL(fileURLWithPath: cachePath)
        } else {
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            cacheURL = documents.appendingPathComponent("chapters").appendingPathComponent(cachePath)
        }
        
        guard FileManager.default.fileExists(atPath: cacheURL.path) else {
            throw ReaderError.notCached
        }
        
        return try String(contentsOf: cacheURL, encoding: .utf8)
    }
    
    /// 统一处理章节正文：图片章节 → 图片列表；文本章节 → 走替换规则
    private func applyContent(_ raw: String, chapter: BookChapter) {
        if raw.hasPrefix(LocalChapter.imagesMarker) {
            let lines = raw.components(separatedBy: "\n")
            let paths = lines
                .dropFirst()
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }

            chapterImages = paths
                .map { URL(fileURLWithPath: $0) }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
            chapterContent = nil
            totalPages = 1
        } else {
            chapterImages = []
            // 已缓存的历史正文可能带 HTML（旧版本没净化），渲染前统一清一次
            let cleaned = WebBook.sanitizeHTML(raw)
            chapterContent = applyReplaceRulesIfNeeded(cleaned, chapter: chapter)
        }
    }

    private func fetchChapterContent(_ chapter: BookChapter) async throws -> String {
        guard let book = currentBook else {
            throw ReaderError.noBook
        }
        
        // 本地书籍直接返回 TXT 切片内容
        if book.origin == "local" {
            return try await loadLocalChapterContent(chapter)
        }
        
        // 网络书籍：通过 WebBook 从书源获取
        guard let sourceId = UUID(uuidString: book.origin) else {
            throw ReaderError.noSource
        }
        
        // 查找对应书源
        let request: NSFetchRequest<BookSource> = BookSource.fetchRequest()
        request.predicate = NSPredicate(format: "sourceId == %@", sourceId as CVarArg)
        
        guard let source = try? CoreDataStack.shared.viewContext.fetch(request).first else {
            throw ReaderError.noSource
        }
        
        return try await WebBook.getContent(source: source, book: book, chapter: chapter)
    }
    
    /// 加载本地书籍的章节内容
    private func loadLocalChapterContent(_ chapter: BookChapter) async throws -> String {
        // 1.1 起导入时已把每章正文落盘（绝对路径缓存），直接命中
        if let cachePath = chapter.cachePath,
           cachePath.hasPrefix("/"),
           FileManager.default.fileExists(atPath: cachePath),
           let text = try? String(contentsOfFile: cachePath, encoding: .utf8) {
            return text
        }

        guard let book = currentBook else { throw ReaderError.noBook }

        // 兜底：旧版本导入的书没有章节缓存，用统一解析器重新解析
        let url = URL(fileURLWithPath: book.bookUrl)
        let result = try await LocalBookParser.parse(url: url)
        let index = Int(chapter.index)
        guard index >= 0, index < result.chapters.count else {
            throw ReaderError.notCached
        }
        return result.chapters[index].content
    }
    
    // MARK: - 缓存全部章节

    @Published var isCachingAll = false
    @Published var cacheCompleted = 0
    @Published var cacheTotal = 0

    /// 逐章抓取并写入缓存，跳过已缓存的章节
    func cacheAllChapters() async {
        guard !isCachingAll, let book = currentBook else { return }

        let pending = chapters.filter { !$0.isCached }
        guard !pending.isEmpty else {
            errorMessage = "全部章节已缓存"
            return
        }

        let context = CoreDataStack.shared.viewContext
        guard let source = BookSourceResolver.resolve(for: book, in: context) else {
            errorMessage = "原书源已删除或不可用，无法缓存"
            return
        }

        isCachingAll = true
        cacheTotal = pending.count
        cacheCompleted = 0

        AppLogger.info("Cache", "开始缓存全书 \(book.name) 待缓存=\(pending.count)")

        for chapter in pending {
            if Task.isCancelled { break }
            do {
                let content = try await WebBook.getContent(source: source, book: book, chapter: chapter)
                try await cacheChapter(chapter, content: content)
                cacheCompleted += 1
            } catch {
                AppLogger.warn("Cache", "缓存失败 \(chapter.title)：\(error)")
            }
        }

        try? context.save()
        isCachingAll = false
        AppLogger.info("Cache", "缓存结束 \(cacheCompleted)/\(cacheTotal)")
    }

    /// 把 NSURLError 这类「天书」翻译成用户能看懂的原因
    static func friendlyError(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case -1000:
                return "章节地址不合法（为空或含非法字符），可尝试换源"
            case -1001:
                return "请求超时，可稍后重试或换源"
            case -1003, -1004:
                return "无法连接站点，可能已失效，建议换源"
            case -1009:
                return "网络未连接"
            case -1022:
                return "系统限制该 http 站点（ATS），建议换源"
            default:
                break
            }
        }
        return error.localizedDescription
    }

    private func cacheChapter(_ chapter: BookChapter, content: String) async throws {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let chapterDir = documents.appendingPathComponent("chapters", isDirectory: true)
        
        if !FileManager.default.fileExists(atPath: chapterDir.path) {
            try FileManager.default.createDirectory(at: chapterDir, withIntermediateDirectories: true)
        }
        
        let fileName = "\(chapter.bookId.uuidString)_\(chapter.index).txt"
        let fileURL = chapterDir.appendingPathComponent(fileName)
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
        
        chapter.isCached = true
        chapter.cachePath = fileName
        try? CoreDataStack.shared.save()
    }
    
    // MARK: - 保存进度
    func saveProgress() {
        guard let book = currentBook else { return }
        
        book.durChapterIndex = Int32(currentChapterIndex)
        book.durChapterTime = Int64(Date().timeIntervalSince1970)
        book.durChapterPos = durChapterPos
        
        if let chapter = currentChapter {
            book.durChapterTitle = chapter.title
        }
        
        try? CoreDataStack.shared.save()
    }

    func saveReadingProgress() async {
        saveProgress()
    }
    
}

extension ReaderViewModel {
    var currentContent: String? {
        get { chapterContent }
        set { chapterContent = newValue }
    }

    var chapterList: [BookChapter] {
        chapters
    }
}

enum ReaderError: LocalizedError {
    case noChapters
    case invalidChapterIndex
    case notCached
    case networkFailure
    case noBook
    case noSource
    case parseFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .noChapters: return "没有章节"
        case .invalidChapterIndex: return "无效的章节索引"
        case .notCached: return "章节未缓存"
        case .networkFailure: return "网络加载失败"
        case .noBook: return "未找到书籍"
        case .noSource: return "原书源已删除或不可用，请换源后重试"
        case .parseFailed(let reason): return "解析失败：\(reason)"
        }
    }
}
// MARK: - 设置视图
struct ReaderSettingsView: View {
    @ObservedObject var viewModel: ReaderViewModel
    @Binding var isPresented: Bool
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("字体")) {
                    Stepper("字号：\(Int(viewModel.fontSize))", value: $viewModel.fontSize, in: 12...32, step: 1)
                    Stepper(
                        "字距：\(String(format: "%.1f", Double(viewModel.letterSpacing)))",
                        value: $viewModel.letterSpacing,
                        in: 0...1,
                        step: 0.1
                    )
                }

                Section(header: Text("间距")) {
                    Stepper("行距：\(Int(viewModel.lineSpacing))", value: $viewModel.lineSpacing, in: 0...30, step: 1)
                    Stepper("段距：\(Int(viewModel.paragraphSpacing))", value: $viewModel.paragraphSpacing, in: 0...10, step: 1)
                    Stepper("缩进：\(Int(viewModel.firstLineIndentChars)) 字", value: $viewModel.firstLineIndentChars, in: 0...4, step: 1)
                    Toggle("两端对齐", isOn: $viewModel.textJustified)
                }

                // 对齐 Android ReadStyleDialog 的标题设置（titleMode / titleSize）
                Section(header: Text("章节标题")) {
                    Picker("显示方式", selection: $viewModel.chapterTitleMode) {
                        Text("居左").tag(0)
                        Text("居中").tag(1)
                        Text("隐藏").tag(2)
                    }
                    .pickerStyle(.segmented)

                    Stepper("标题字号 +\(Int(viewModel.chapterTitleSizeDelta))", value: $viewModel.chapterTitleSizeDelta, in: 0...12, step: 1)
                }
                
                Section(header: Text("主题")) {
                    Button("亮色") {
                        viewModel.applyTheme(.light)
                    }
                    
                    Button("暗色") {
                        viewModel.applyTheme(.dark)
                    }
                    
                    Button("护眼") {
                        viewModel.applyTheme(.eyeProtection)
                    }
                    
                    Button("羊皮纸") {
                        viewModel.applyTheme(.sepia)
                    }
                }
            }
            .navigationTitle("阅读设置")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") {
                        isPresented = false
                    }
                }
            }
        }
    }
}

// MARK: - 目录列表
struct ChapterListView: View {
    @ObservedObject var viewModel: ReaderViewModel
    let book: Book
    @Environment(\.dismiss) var dismiss
    
    /// 倒序显示（对齐 Android TocActivity 的「反转目录」）
    @State private var isReversed = false

    private var orderedChapters: [(index: Int, chapter: BookChapter)] {
        let list = Array(viewModel.chapters.enumerated())
            .map { (index: $0.offset, chapter: $0.element) }
        return isReversed ? list.reversed() : list
    }

    var body: some View {
        NavigationView {
            ScrollViewReader { proxy in
                List {
                    ForEach(orderedChapters, id: \.chapter.chapterId) { item in
                        if item.chapter.isVolume {
                            // 分卷标题行（对齐 Android 的卷头，不可点击跳转）
                            HStack {
                                Image(systemName: "book.closed")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)

                                Text(item.chapter.title)
                                    .font(.subheadline.weight(.semibold))

                                Spacer()
                            }
                            .padding(.vertical, 2)
                            .id(item.chapter.chapterId)
                        } else {
                            Button(action: {
                                viewModel.jumpToChapter(item.index)
                                dismiss()
                            }) {
                                HStack {
                                    Text("\(item.index + 1)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .frame(width: 40, alignment: .leading)

                                    Text(item.chapter.title)
                                        .font(item.index == viewModel.currentChapterIndex ? .body.weight(.semibold) : .body)
                                        .foregroundColor(item.index == viewModel.currentChapterIndex ? .accentColor : .primary)
                                        .lineLimit(2)

                                    Spacer()

                                    if item.chapter.isCached {
                                        Image(systemName: "arrow.down.circle.fill")
                                            .foregroundColor(.green)
                                            .font(.caption)
                                    }
                                }
                                .id(item.chapter.chapterId)
                            }
                        }
                    }
                }
                .onAppear {
                    // 打开目录自动定位到当前章
                    if viewModel.currentChapterIndex >= 0,
                       viewModel.currentChapterIndex < viewModel.chapters.count {
                        let current = viewModel.chapters[viewModel.currentChapterIndex]
                        proxy.scrollTo(current.chapterId, anchor: .center)
                    }
                }
            }
            .navigationTitle("目录 \(viewModel.currentChapterIndex + 1)/\(viewModel.chapters.count)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(isReversed ? "正序" : "倒序") {
                        isReversed.toggle()
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
        }
    }
}
