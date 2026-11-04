//
//  PagedReaderView.swift
//  Legado-iOS
//
//  分页阅读容器视图
//  根据用户设置的翻页动画类型切换不同的翻页实现
//

import SwiftUI

struct PagedReaderView: View {
    @ObservedObject var viewModel: ReaderViewModel
    @AppStorage("pageAnimation") var pageAnimationRaw: String = PageAnimationType.cover.rawValue
    /// 全屏阅读时补的安全区（刘海 / Home 指示条），保证文字不被遮挡
    var extraInsets: EdgeInsets = EdgeInsets()
    let onTap: () -> Void
    
    @State private var pages: [String] = []
    @State private var containerSize: CGSize = .zero
    /// 分页竞态令牌：连续切章时只让最后一次结果生效
    @StateObject private var splitCoordinator = SplitCoordinator()

    private var currentPageBinding: Binding<Int> {
        Binding(
            get: { viewModel.currentPageIndex },
            set: { viewModel.currentPageIndex = $0 }
        )
    }
    
    private var pageAnimation: PageAnimationType {
        PageAnimationType(rawValue: pageAnimationRaw) ?? .slide
    }
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                viewModel.backgroundColor.ignoresSafeArea()

                if !viewModel.chapterImages.isEmpty {
                    // CBZ 等图片章节：直接纵向滚动看图
                    ImageChapterScrollView(images: viewModel.chapterImages)
                } else if pages.isEmpty {
                    if viewModel.isLoading {
                        ProgressView()
                    } else if viewModel.chapterContent != nil {
                        // 有内容但还没分页（首次加载）
                        ProgressView("分页中...")
                    } else {
                        Text("暂无内容")
                            .foregroundColor(.secondary)
                    }
                } else {
                    pageView
                }
                
                // 页码指示器
                if !pages.isEmpty && viewModel.chapterImages.isEmpty {
                    VStack {
                        Spacer()
                        pageIndicator
                    }
                }
            }
            .onAppear {
                containerSize = geometry.size
                splitPages()
            }
            .onChange(of: geometry.size) { newSize in
                containerSize = newSize
                splitPages()
            }
            .onChange(of: viewModel.chapterContent) { _ in
                splitPages()
            }
            .onChange(of: viewModel.fontSize) { _ in
                invalidateAndResplit()
            }
            .onChange(of: viewModel.lineSpacing) { _ in
                invalidateAndResplit()
            }
            .onChange(of: viewModel.paragraphSpacing) { _ in
                invalidateAndResplit()
            }
            .onChange(of: viewModel.letterSpacing) { _ in
                invalidateAndResplit()
            }
            .onChange(of: viewModel.firstLineIndentChars) { _ in
                invalidateAndResplit()
            }
            .onChange(of: viewModel.lineHeightMultiple) { _ in
                invalidateAndResplit()
            }
            .onChange(of: viewModel.textJustified) { _ in
                invalidateAndResplit()
            }
            .onChange(of: viewModel.fontFamily) { _ in
                invalidateAndResplit()
            }
        }
    }
    
    // MARK: - 翻页视图切换
    
    @ViewBuilder
    private var pageView: some View {
        switch pageAnimation {
        case .cover:
            CoverPageView(
                viewModel: viewModel,
                pages: pages,
                currentPage: currentPageBinding,
                onTap: onTap
            )
            
        case .slide:
            SlidePageView(
                viewModel: viewModel,
                pages: pages,
                currentPage: currentPageBinding,
                onTap: onTap
            )
            
        case .scroll:
            scrollView
            
        case .simulation:
            CurlPageView(
                viewModel: viewModel,
                pages: pages,
                currentPage: currentPageBinding,
                onTap: onTap
            )
            
        case .none:
            InstantPageView(
                viewModel: viewModel,
                pages: pages,
                currentPage: currentPageBinding,
                onTap: onTap
            )
        }
    }
    
    // MARK: - 滚动视图（保留原有滚动模式）
    
    private var scrollView: some View {
        ScrollView {
            if let content = viewModel.chapterContent {
                Text(content)
                    .font(viewModel.readerFont)
                    .foregroundColor(viewModel.textColor)
                    .lineSpacing(viewModel.effectiveLineSpacing)
                    .kerning(viewModel.letterSpacing)
                    .padding(viewModel.pagePadding)
                    .textSelection(.enabled)
            }
        }
        .background(viewModel.backgroundColor)
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
    }
    
    // MARK: - 页码指示器
    
    private var pageIndicator: some View {
        HStack(spacing: 4) {
            Text("\(min(viewModel.currentPageIndex + 1, pages.count)) / \(pages.count)")
                .font(.caption2)
                .foregroundColor(.secondary)
            
            if viewModel.totalChapters > 0 {
                Text("·")
                    .foregroundColor(.secondary.opacity(0.5))
                Text("第\(viewModel.currentChapterIndex + 1)章")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
        )
        .padding(.bottom, 8)
    }
    
    // MARK: - 分页逻辑
    
    private func splitPages() {
        guard let content = viewModel.chapterContent, !content.isEmpty else {
            pages = []
            return
        }

        guard containerSize.width > 0, containerSize.height > 0 else { return }

        let config = viewModel.makePageConfig(
            containerSize: containerSize,
            extraTop: extraInsets.top,
            extraBottom: extraInsets.bottom,
            chapterTitle: viewModel.currentChapter?.title
        )

        // 对齐 Android：分页在 IO 线程增量产出（TextChapterLayout 用协程分页），
        // 主线程只负责展示，避免长章节把界面卡住。
        let token = splitCoordinator.begin()
        let text = content

        Task.detached(priority: .userInitiated) {
            let result = PageSplitCache.shared.getOrSplit(text: text, config: config)

            await MainActor.run {
                guard splitCoordinator.isCurrent(token) else { return }

                let oldPage = viewModel.currentPageIndex
                pages = result.pages
                viewModel.totalPages = result.totalPages

                // 保持页码在有效范围内
                if oldPage >= pages.count {
                    viewModel.currentPageIndex = max(0, pages.count - 1)
                }
            }
        }
    }
    
    private func invalidateAndResplit() {
        PageSplitCache.shared.invalidate()
        splitPages()
    }
}

// MARK: - 翻页动画类型（与 ReaderSettingsFullView.PageAnimation 对齐）

enum PageAnimationType: String, CaseIterable, Identifiable {
    case cover = "覆盖"
    case simulation = "仿真"
    case slide = "滑动"
    case scroll = "滚动"
    case none = "无动画"
    
    var id: String { self.rawValue }
}

// MARK: - 无动画翻页

struct InstantPageView: View {
    @ObservedObject var viewModel: ReaderViewModel
    let pages: [String]
    @Binding var currentPage: Int
    let onTap: () -> Void
    
    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            
            ZStack {
                viewModel.backgroundColor
                
                if currentPage >= 0 && currentPage < pages.count {
                    PageTextView(text: pages[currentPage], viewModel: viewModel)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { location in
                // 对齐 Android 九宫格：左列上一页、正中菜单、其余下一页
                switch ReaderTapZone.action(for: location, in: geometry.size) {
                case .prevPage:
                    if currentPage > 0 {
                        currentPage -= 1
                        viewModel.currentPageIndex = currentPage
                    } else {
                        Task { await viewModel.prevChapter() }
                    }
                case .nextPage:
                    if currentPage + 1 < pages.count {
                        currentPage += 1
                        viewModel.currentPageIndex = currentPage
                    } else {
                        Task { await viewModel.nextChapter() }
                    }
                case .menu:
                    onTap()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 30)
                    .onEnded { value in
                        if value.translation.width < -50 && currentPage + 1 < pages.count {
                            currentPage += 1
                            viewModel.currentPageIndex = currentPage
                        } else if value.translation.width > 50 && currentPage > 0 {
                            currentPage -= 1
                            viewModel.currentPageIndex = currentPage
                        }
                    }
            )
        }
    }
}

// MARK: - 点击区域（对齐 Android ReadView.setRect9x 的默认映射）

enum ReaderTapZone {

    enum Action {
        case prevPage
        case nextPage
        case menu
    }

    /// X / Y 各三等分（Android `setRect9x()`：0~0.33 / 0.33~0.66 / 0.66~1.0）
    /// 默认动作：左列上一页、正中菜单、其余下一页
    /// 对应 `AppConfig.kt:54-62`（TL/TC/ML/BL → 上一页，MC → 菜单，TR/MR/BC/BR → 下一页）
    static func action(for location: CGPoint, in size: CGSize) -> Action {
        guard size.width > 0, size.height > 0 else { return .menu }

        let xRatio = location.x / size.width
        let yRatio = location.y / size.height
        let mode = UserDefaults.standard.string(forKey: "reader.tapZoneMode") ?? "nineGrid"

        switch mode {
        case "threeColumn":
            // 左右各 1/3 翻页，中间唤菜单（不分上下）
            if xRatio < 1.0 / 3.0 { return .prevPage }
            if xRatio > 2.0 / 3.0 { return .nextPage }
            return .menu

        case "fullTap":
            // 上半屏上一页、下半屏下一页（菜单从顶栏唤出）
            return yRatio < 0.5 ? .prevPage : .nextPage

        default:
            // 九宫格（Android setRect9x 默认）
            let column = min(2, max(0, Int(xRatio * 3)))
            let row = min(2, max(0, Int(yRatio * 3)))

            switch (column, row) {
            case (0, _):
                return .prevPage
            case (1, 1):
                return .menu
            default:
                return .nextPage
            }
        }
    }
}

// MARK: - 分页竞态控制

/// 连续切章 / 改字号时会多次触发分页，只允许最后一次的结果写回界面
final class SplitCoordinator: ObservableObject {
    private(set) var token = UUID()

    func begin() -> UUID {
        token = UUID()
        return token
    }

    func isCurrent(_ candidate: UUID) -> Bool {
        candidate == token
    }
}
