//
//  SlidePageView.swift
//  Legado-iOS
//
//  滑动翻页动画：使用 TabView 实现平滑水平滑动
//

import SwiftUI

struct SlidePageView: View {
    @ObservedObject var viewModel: ReaderViewModel
    let pages: [String]
    @Binding var currentPage: Int
    let onTap: () -> Void
    
    var body: some View {
        TabView(selection: $currentPage) {
            ForEach(Array(pages.enumerated()), id: \.offset) { index, page in
                SinglePageContent(
                    text: page,
                    viewModel: viewModel,
                    pages: pages,
                    currentPage: $currentPage,
                    onTap: onTap
                )
                .tag(index)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .onChange(of: currentPage) { newValue in
            viewModel.currentPageIndex = newValue
        }
    }
}

// MARK: - 单页内容

private struct SinglePageContent: View {
    let text: String
    @ObservedObject var viewModel: ReaderViewModel
    let pages: [String]
    @Binding var currentPage: Int
    let onTap: () -> Void

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                viewModel.backgroundColor

                PageTextView(text: text, viewModel: viewModel)
            }
            .contentShape(Rectangle())
            .onTapGesture { location in
                switch ReaderTapZone.action(for: location, in: geometry.size) {
                case .prevPage:
                    if currentPage > 0 {
                        currentPage -= 1
                    } else {
                        Task { await viewModel.prevChapter() }
                    }
                case .nextPage:
                    if currentPage + 1 < pages.count {
                        currentPage += 1
                    } else {
                        Task { await viewModel.nextChapter() }
                    }
                case .menu:
                    onTap()
                }
            }
        }
    }
}
