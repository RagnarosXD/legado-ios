//
//  ReaderView.swift
//  Legado-iOS
//
//  阅读器主界面
//

import SwiftUI
import CoreData

struct ReaderView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel = ReaderViewModel()
    @StateObject private var ttsManager = TTSManager()
    @StateObject private var autoPageTurnManager = AutoPageTurnManager()
    @StateObject private var readingEnhancementManager = ReadingEnhancementManager()
    
    @State private var showingSettings = false
    @State private var showingChapterList = false
    @State private var showingTTSControls = false
    @State private var showingAutoPageTurn = false
    @State private var showingChangeSource = false
    @State private var showingBookmarks = false
    @State private var showUI = true
    
    let book: Book
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // 背景色
                viewModel.backgroundColor
                    .ignoresSafeArea()
                
                // 内容区域：铺满整屏（含状态栏/Home 指示条区域），与 Android 阅读器一致
                PagedReaderView(
                    viewModel: viewModel,
                    extraInsets: EdgeInsets(
                        top: geometry.safeAreaInsets.top,
                        leading: 0,
                        bottom: geometry.safeAreaInsets.bottom,
                        trailing: 0
                    )
                ) {
                    autoPageTurnManager.handleTouch()
                    withAnimation { showUI.toggle() }
                }
                .ignoresSafeArea()
                
                // MARK: - 顶部工具栏（精简版）
                VStack {
                    HStack(spacing: 6) {
                        Button(action: {
                            viewModel.saveProgress()
                            dismiss()
                        }) {
                            Image(systemName: "chevron.left")
                                .font(.body)
                                .frame(width: 40, height: 36)
                        }

                        Text(book.name)
                            .font(.caption)
                            .lineLimit(1)

                        if let title = viewModel.currentChapter?.title, !title.isEmpty {
                            Text("· \(title)")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 4)

                        Button(action: { showingChapterList = true }) {
                            Image(systemName: "list.bullet")
                                .font(.body)
                                .frame(width: 40, height: 36)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.top, geometry.safeAreaInsets.top + 2)
                    .padding(.bottom, 2)
                    .background(.ultraThinMaterial)
                    .opacity(showUI ? 1.0 : 0.0)
                    .animation(.easeInOut(duration: 0.25), value: showUI)
                    
                    Spacer()
                    
                    // MARK: - 底部工具栏（紧凑版）
                    VStack(spacing: 0) {
                        if viewModel.isCachingAll {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.mini)
                                Text("缓存中 \(viewModel.cacheCompleted)/\(viewModel.cacheTotal)")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Spacer()
                            }
                            .padding(.horizontal, 16)
                            .padding(.top, 4)
                        }

                        // 章节进度：一行（上一章 + 滑块 + 下一章 + 序号）
                        HStack(spacing: 8) {
                            Button(action: { Task { await viewModel.prevChapter() } }) {
                                Image(systemName: "chevron.left")
                                    .font(.caption)
                                    .frame(width: 26, height: 26)
                            }
                            .disabled(viewModel.currentChapterIndex <= 0)
                            .opacity(viewModel.currentChapterIndex <= 0 ? 0.35 : 1)

                            Slider(value: Binding(
                                get: { Double(viewModel.currentChapterIndex) },
                                set: { viewModel.jumpToChapter(Int($0)) }
                            ), in: 0...Double(max(1, viewModel.totalChapters - 1)), step: 1)
                            .controlSize(.mini)

                            Button(action: { Task { await viewModel.nextChapter() } }) {
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .frame(width: 26, height: 26)
                            }
                            .disabled(viewModel.currentChapterIndex >= viewModel.totalChapters - 1)
                            .opacity(viewModel.currentChapterIndex >= viewModel.totalChapters - 1 ? 0.35 : 1)

                            Text("\(viewModel.currentChapterIndex + 1)/\(viewModel.totalChapters)")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .monospacedDigit()
                                .frame(minWidth: 44, alignment: .trailing)
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, 6)
                        .padding(.bottom, 2)

                        // 工具栏
                        HStack(spacing: 0) {
                            ToolBarButton(icon: "a.square", title: "设置") { showingSettings = true }
                            ToolBarButton(icon: "speaker.wave.2", title: "朗读") { showingTTSControls = true }
                            ToolBarButton(icon: "timer", title: "自动") { showingAutoPageTurn = true }
                            ToolBarButton(icon: "bookmark", title: "书签") { showingBookmarks = true }
                            ToolBarButton(icon: "arrow.triangle.2.circlepath", title: "换源") { showingChangeSource = true }
                            ToolBarButton(icon: "arrow.down.circle", title: "缓存") {
                                Task { await viewModel.cacheAllChapters() }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .padding(.bottom, geometry.safeAreaInsets.bottom)
                    .background(.ultraThinMaterial)
                    .opacity(showUI ? 1.0 : 0.0)
                    .animation(.easeInOut(duration: 0.25), value: showUI)
                }
                
                // 设置面板
                if showingSettings {
                    ReaderSettingsView(viewModel: viewModel, isPresented: $showingSettings)
                        .transition(.move(edge: .bottom))
                }
                
                if showingTTSControls {
                    TTSControlsView(ttsManager: ttsManager, viewModel: viewModel, isPresented: $showingTTSControls)
                        .transition(.opacity)
                }
                
                if showingAutoPageTurn {
                    AutoPageTurnControlsView(manager: autoPageTurnManager, isPresented: $showingAutoPageTurn)
                        .transition(.opacity)
                }
                
                AutoPageTurnOverlay(manager: autoPageTurnManager)
                
                // 加载指示器
                if viewModel.isLoading {
                    ProgressView()
                        .scaleEffect(1.5)
                        .padding()
                        .background(Color.black.opacity(0.7))
                        .foregroundColor(.white)
                        .cornerRadius(10)
                }
                
                // 错误提示
                if let error = viewModel.errorMessage {
                    VStack {
                        Text(error)
                            .foregroundColor(.white)
                            .padding()
                            .background(Color.red.opacity(0.8))
                            .cornerRadius(8)
                    }
                    .padding()
                }
            }
            .onAppear {
                viewModel.loadBook(book)
                autoPageTurnManager.onTurnPage = { viewModel.turnToNextPage() }
                autoPageTurnManager.onChapterComplete = {
                    Task { @MainActor in
                        await viewModel.nextChapter()
                    }
                }
                readingEnhancementManager.onNightModeChanged = { isNight in
                    viewModel.applyTheme(isNight ? .dark : .light)
                }
                readingEnhancementManager.startReadingSession()
            }
            .onDisappear {
                viewModel.saveProgress()
                ttsManager.stop()
                autoPageTurnManager.stop()
                readingEnhancementManager.endReadingSession()
            }
            .onChange(of: viewModel.currentPageIndex) { _ in
                autoPageTurnManager.reset()
            }
            .alert("阅读提醒", isPresented: Binding(
                get: { readingEnhancementManager.showReminder },
                set: { newValue in
                    if !newValue {
                        readingEnhancementManager.dismissReminder()
                    }
                }
            )) {
                Button("知道了") {
                    readingEnhancementManager.dismissReminder()
                }
            } message: {
                Text("阅读一段时间了，休息一下眼睛。")
            }
            .sheet(isPresented: $showingChapterList) {
                ChapterListView(viewModel: viewModel, book: book)
            }
            .sheet(isPresented: $showingChangeSource) {
                ChangeSourceSheet(isPresented: $showingChangeSource, book: book) {
                    viewModel.loadBook(book)
                }
            }
            .sheet(isPresented: $showingBookmarks) {
                BookmarkSheet(viewModel: viewModel, book: book)
            }
        }
        .navigationBarHidden(true)
        .statusBar(hidden: !showUI)
        // 阅读页全屏：隐藏底部 TabBar（书架/我的），退出阅读器自动恢复
        .toolbar(.hidden, for: .tabBar)
        // 沉浸模式：隐藏 Home 指示条，与 Android 全屏阅读一致
        .persistentSystemOverlays(showUI ? .automatic : .hidden)
    }
}

// MARK: - 工具栏按钮组件
struct ToolBarButton: View {
    let icon: String
    let title: String
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: icon)
                    .font(.body)
                Text(title)
                    .font(.system(size: 10))
            }
            .frame(maxWidth: .infinity)
            .foregroundColor(.primary)
            .padding(.vertical, 2)
        }
    }
}

// MARK: - 旧分页视图（保留向后兼容）
struct ReaderPageView: View {
    @ObservedObject var viewModel: ReaderViewModel
    
    var body: some View {
        PagedReaderView(viewModel: viewModel) {
            // 默认无操作
        }
    }
}

#Preview {
    Text("ReaderView Preview")
}