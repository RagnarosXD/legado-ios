//
//  SearchResultView.swift
//  Legado-iOS
//
//  搜索结果视图
//

import SwiftUI

struct SearchResultView: View {
    @StateObject private var viewModel = SearchViewModel()
    @State private var showingSourcePicker = false
    @State private var navigatingToBookDetail = false
    @State private var selectedBook: Book?
    @State private var openingResultId: UUID?
    @State private var choosingMerged: SearchViewModel.MergedSearchResult?

    var body: some View {
        VStack(spacing: 0) {
            // 搜索进度：已搜索书源数 / 书源总数
            if viewModel.isSearching {
                VStack(spacing: 6) {
                    ProgressView(value: viewModel.progress)
                        .progressViewStyle(.linear)
                    HStack {
                        Text("已搜索 \(viewModel.searchedSourceCount)/\(viewModel.totalSourceCount) 个书源")
                        Spacer()
                        Text("\(Int(viewModel.progress * 100))%")
                    }
                    .font(.caption2)
                    .foregroundColor(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }

            if viewModel.mergedResults.isEmpty {
                if viewModel.isSearching {
                    Spacer()
                } else {
                    EmptyStateView(
                        title: "搜索结果",
                        subtitle: "输入关键词搜索书籍",
                        imageName: "magnifyingglass"
                    )
                }
            } else {
                List(viewModel.mergedResults) { merged in
                    Button {
                        handleTap(merged)
                    } label: {
                        SearchResultItemView(
                            result: merged.entries[0],
                            sourceCount: merged.entries.count
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(merged.primary.map { openingResultId == $0.id } ?? false)
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("搜索")
        .searchable(text: $viewModel.searchText, prompt: "搜索书籍")
        .onSubmit(of: .search) {
            Task {
                await viewModel.search(keyword: viewModel.searchText, sources: viewModel.selectedSources)
            }
        }
        .toolbar {
            ToolbarItem {
                Button(action: { showingSourcePicker = true }) {
                    Label("书源", systemImage: "square.grid.2x2")
                }
            }
        }
        .sheet(isPresented: $showingSourcePicker) {
            SourcePickerView(selectedSources: $viewModel.selectedSources)
        }
        .navigationDestination(isPresented: $navigatingToBookDetail) {
            if let book = selectedBook {
                BookDetailView(book: book)
            } else {
                Text("未找到书籍")
            }
        }
        .alert("提示", isPresented: Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )) {
            Button("确定", role: .cancel) {
                viewModel.errorMessage = nil
            }
        } message: {
            Text(viewModel.errorMessage ?? "未知错误")
        }
        .confirmationDialog(
            "选择书源",
            isPresented: Binding(
                get: { choosingMerged != nil },
                set: { if !$0 { choosingMerged = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let merged = choosingMerged {
                ForEach(merged.entries, id: \.id) { entry in
                    Button(entry.sourceName) {
                        open(entry)
                    }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            if let merged = choosingMerged {
                Text("《\(merged.name)》在 \(merged.entries.count) 个书源里都有，选一个加入书架")
            }
        }
    }

    // MARK: - 交互

    private func handleTap(_ merged: SearchViewModel.MergedSearchResult) {
        guard let primary = merged.primary else { return }
        // 多书源时让用户选择（对标 Android 的「换源」入口）
        if merged.entries.count > 1 {
            choosingMerged = merged
        } else {
            open(primary)
        }
    }

    private func open(_ result: SearchViewModel.SearchResult) {
        guard openingResultId == nil else { return }
        choosingMerged = nil
        openingResultId = result.id

        Task {
            defer { openingResultId = nil }
            do {
                selectedBook = try await viewModel.addToBookshelf(result: result)
                navigatingToBookDetail = true
            } catch {
                viewModel.errorMessage = "加入书架失败：\(error.localizedDescription)"
            }
        }
    }
}

struct SearchResultItemView: View {
    let result: SearchViewModel.SearchResult
    var sourceCount: Int = 1

    var body: some View {
        HStack(spacing: 12) {
            // 封面
            BookCoverView(url: result.coverUrl)
                .frame(width: 60, height: 80)
                .background(Color.gray.opacity(0.1))
                .cornerRadius(4)
            
            VStack(alignment: .leading, spacing: 4) {
                // 书名
                Text(result.displayName)
                    .font(.body)
                    .fontWeight(.medium)
                    .lineLimit(1)
                
                // 作者
                Text(result.displayAuthor)
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                // 书源（聚合后显示来源数量）
                HStack(spacing: 4) {
                    Text(result.sourceName)
                    if sourceCount > 1 {
                        Text("等 \(sourceCount) 个源")
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.blue.opacity(0.12))
                            .cornerRadius(3)
                    }
                }
                .font(.caption2)
                .foregroundColor(.blue)
                
                // 简介
                if let intro = result.intro {
                    Text(intro)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }
            
            Spacer()
        }
    }
}

struct SourcePickerView: View {
    @Binding var selectedSources: [BookSource]
    @Environment(\.dismiss) var dismiss
    @State private var sources: [BookSource] = []
    
    var body: some View {
        NavigationView {
            List {
                ForEach(sources, id: \.sourceId) { source in
                    HStack {
                        Text(source.displayName)

                        if !source.supportsTextSearch {
                            Text(source.typeDisplayName)
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.orange.opacity(0.15))
                                .foregroundColor(.orange)
                                .cornerRadius(4)
                        }

                        Spacer()

                        if !source.supportsTextSearch {
                            Text("本版本不支持")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        } else if selectedSources.contains(where: { $0.sourceId == source.sourceId }) {
                            Image(systemName: "checkmark")
                                .foregroundColor(.blue)
                        }
                    }
                    .opacity(source.supportsTextSearch ? 1 : 0.5)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        toggleSource(source)
                    }
                }
            }
            .navigationTitle("选择书源")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
            .task {
                await loadSources()
            }
        }
    }
    
    private func loadSources() async {
        do {
            sources = try CoreDataStack.shared.viewContext.fetch(BookSource.fetchRequest())
        } catch {
            print("加载书源失败：\(error)")
        }
    }
    
    private func toggleSource(_ source: BookSource) {
        // 有声/漫画源不参与搜索，避免用文本解析器处理它们而崩溃
        guard source.supportsTextSearch else { return }

        if let index = selectedSources.firstIndex(where: { $0.sourceId == source.sourceId }) {
            selectedSources.remove(at: index)
        } else {
            selectedSources.append(source)
        }
    }
}

#Preview {
    SearchResultView()
}
