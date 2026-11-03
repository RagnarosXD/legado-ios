//
//  BookshelfView.swift
//  Legado-iOS
//
//  书架主界面
//

import SwiftUI
import CoreData
import UniformTypeIdentifiers

struct BookshelfView: View {
    @StateObject private var viewModel = BookshelfViewModel()
    @StateObject private var localBookViewModel = LocalBookViewModel()
    @State private var showingSourceManage = false
    @State private var showingAddBook = false
    @State private var showingSearch = false
    /// 长按菜单里选中的待换源书籍
    @State private var changeSourceBook: Book?
    /// 批量管理（对齐 Android BookshelfManageActivity）
    @State private var isSelecting = false
    @State private var selectedBookIds: Set<UUID> = []
    @State private var showingGroupPicker = false
    /// 网格列数（对齐 Android bookshelfLayout：≥2 为网格列数）
    @AppStorage("bookshelfColumns") private var columns: Int = 3
    /// 是否显示书名（对齐 Android showBookname）
    @AppStorage("bookshelfShowName") private var showBookName: Bool = true
    
    var body: some View {
        Group {
            if viewModel.books.isEmpty && !viewModel.isLoading {
                EmptyStateView(
                    title: "书架空空如也",
                    subtitle: "点击右上角添加书籍或导入书源",
                    imageName: "books.vertical"
                )
            } else {
                bookshelfContent
            }
        }
        .navigationTitle("书架")
        .safeAreaInset(edge: .top, spacing: 0) {
            groupBar
        }
        .onChange(of: viewModel.sortBy) { _ in
            Task { await viewModel.loadBooks() }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if isSelecting {
                batchBar
            }
        }
        .confirmationDialog("加入分组", isPresented: $showingGroupPicker, titleVisibility: .visible) {
            ForEach(viewModel.groups, id: \.groupId) { group in
                Button(group.groupName) {
                    viewModel.addBooks(ids: selectedBookIds, toGroup: group.groupId)
                }
            }
            Button("取消", role: .cancel) { }
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Picker("", selection: $viewModel.viewMode) {
                    Image(systemName: "square.grid.2x2")
                        .tag(BookshelfViewModel.ViewMode.grid)
                    Image(systemName: "list.bullet")
                        .tag(BookshelfViewModel.ViewMode.list)
                }
                .pickerStyle(.segmented)
            }
            
ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 12) {
                    Button(isSelecting ? "完成" : "管理") {
                        withAnimation {
                            isSelecting.toggle()
                            if !isSelecting { selectedBookIds.removeAll() }
                        }
                    }

                    Button(action: { showingSearch = true }) {
                        Image(systemName: "magnifyingglass")
                    }

                    // 排序（对齐 Android bookshelfSort 的 6 种）
                    Menu {
                        Picker("排序", selection: $viewModel.sortBy) {
                            ForEach(BookshelfViewModel.SortBy.allCases, id: \.rawValue) { sort in
                                Label(sort.title, systemImage: sort.icon).tag(sort)
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }

                    // 网格列数（Android bookshelfLayout 的 2..N）
                    Menu {
                        Picker("每行列数", selection: $columns) {
                            Text("2 列").tag(2)
                            Text("3 列").tag(3)
                            Text("4 列").tag(4)
                            Text("5 列").tag(5)
                            Text("6 列").tag(6)
                        }
                        Divider()
                        Toggle("显示书名", isOn: $showBookName)
                    } label: {
                        Image(systemName: "square.grid.2x2")
                    }

                    Button(action: { showingSourceManage = true }) {
                        Image(systemName: "gearshape")
                    }
                    
                    Button(action: {
                        DocumentPickerHelper.shared.present(contentTypes: UTType.localBookTypes) { urls in
                            guard let url = urls.first else { return }
                            Task { @MainActor in
                                do {
                                    try await localBookViewModel.importBook(url: url)
                                    await viewModel.forceReload()
                                } catch {
                                    localBookViewModel.errorMessage = "导入失败：\(error.localizedDescription)"
                                }
                            }
                        }
                    }) {
                        Image(systemName: "square.and.arrow.down")
                    }
                    
                    Button(action: { showingAddBook = true }) {
                        Image(systemName: "plus")
                    }
                }
            }
        }
        .sheet(isPresented: $showingSourceManage) {
            SourceManageView()
        }
        .sheet(isPresented: $showingAddBook) {
            AddBookView { url, completion in
                Task {
                    do {
                        try await localBookViewModel.importBook(url: url)
                        await viewModel.forceReload()
                    } catch {
                        await MainActor.run {
                            localBookViewModel.errorMessage = "导入失败：\(error.localizedDescription)"
                        }
                    }
                    completion()
                }
            }
        }
        .sheet(isPresented: $showingSearch) {
            NavigationStack { SearchResultView() }
        }
        .alert("导入成功", isPresented: Binding(
            get: { localBookViewModel.successMessage != nil },
            set: { if !$0 { localBookViewModel.successMessage = nil } }
        )) {
            Button("确定", role: .cancel) { localBookViewModel.successMessage = nil }
        } message: {
            Text(localBookViewModel.successMessage ?? "")
        }
        .alert("导入失败", isPresented: Binding(
            get: { localBookViewModel.errorMessage != nil },
            set: { if !$0 { localBookViewModel.errorMessage = nil } }
        )) {
            Button("确定", role: .cancel) { localBookViewModel.errorMessage = nil }
        } message: {
            Text(localBookViewModel.errorMessage ?? "未知错误")
        }
        .task {
            await viewModel.loadBooks()
        }
        .refreshable {
            await viewModel.refreshBooks()
        }
        .sheet(isPresented: Binding(
            get: { changeSourceBook != nil },
            set: { if !$0 { changeSourceBook = nil } }
        )) {
            if let book = changeSourceBook {
                ChangeSourceSheet(
                    isPresented: Binding(
                        get: { changeSourceBook != nil },
                        set: { if !$0 { changeSourceBook = nil } }
                    ),
                    book: book
                ) {
                    Task { await viewModel.refreshBooks() }
                }
            }
        }
    }
    
    @ViewBuilder
    /// 分组条（对齐 Android 风格1 的分组 Tab）
    private var groupBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                groupChip(title: "全部", id: nil)

                ForEach(viewModel.groups, id: \.groupId) { group in
                    groupChip(title: group.groupName, id: group.groupId)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .background(.bar)
    }

    private func groupChip(title: String, id: Int64?) -> some View {
        let active = viewModel.selectedGroupId == id

        return Button {
            viewModel.selectGroup(id)
        } label: {
            Text(title)
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule().fill(
                        active ? Color.accentColor.opacity(0.16) : Color(.secondarySystemBackground)
                    )
                )
                .overlay(
                    Capsule().stroke(active ? Color.accentColor : Color.clear, lineWidth: 1)
                )
                .foregroundColor(active ? .accentColor : .primary)
        }
        .buttonStyle(.plain)
    }

    private func toggleBookSelection(_ book: Book) {
        if selectedBookIds.contains(book.bookId) {
            selectedBookIds.remove(book.bookId)
        } else {
            selectedBookIds.insert(book.bookId)
        }
    }

    /// 批量操作栏
    private var batchBar: some View {
        HStack(spacing: 14) {
            Button("全选") {
                selectedBookIds = Set(viewModel.books.map { $0.bookId })
            }
            .font(.subheadline)

            Button("反选") {
                let all = Set(viewModel.books.map { $0.bookId })
                selectedBookIds = all.subtracting(selectedBookIds)
            }
            .font(.subheadline)

            Button("加入分组") {
                showingGroupPicker = true
            }
            .font(.subheadline)
            .disabled(selectedBookIds.isEmpty)

            Spacer()

            Text("已选 \(selectedBookIds.count)")
                .font(.caption)
                .foregroundColor(.secondary)

            Button(role: .destructive) {
                viewModel.deleteBooks(ids: selectedBookIds)
                selectedBookIds.removeAll()
                isSelecting = false
            } label: {
                Text("删除")
                    .font(.subheadline)
            }
            .disabled(selectedBookIds.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    @ViewBuilder
    private var bookshelfContent: some View {
        switch viewModel.viewMode {
        case .grid:
            bookGridView
        case .list:
            bookListView
        }
    }
    
    private var bookGridView: some View {
        ScrollView {
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(), spacing: 12),
                    count: max(2, min(6, columns))
                ),
                spacing: 16
            ) {
                ForEach(viewModel.books, id: \.bookId) { book in
                    if isSelecting {
                        Button {
                            toggleBookSelection(book)
                        } label: {
                            ZStack(alignment: .topLeading) {
                                BookGridItemView(book: book, showName: showBookName)

                                Image(systemName: selectedBookIds.contains(book.bookId)
                                      ? "checkmark.circle.fill" : "circle")
                                    .font(.title3)
                                    .foregroundColor(selectedBookIds.contains(book.bookId) ? .accentColor : .white)
                                    .padding(6)
                                    .shadow(radius: 2)
                            }
                        }
                        .buttonStyle(.plain)
                    } else {
                        NavigationLink(destination: ReaderView(book: book)) {
                            BookGridItemView(book: book, showName: showBookName)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button {
                                changeSourceBook = book
                            } label: {
                                Label("换源", systemImage: "arrow.triangle.2.circlepath")
                            }

                            Button(role: .destructive) {
                                viewModel.removeBook(book)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                }
                
                // 加载更多指示器
                if viewModel.isLoading {
                    ProgressView()
                        .padding()
                } else if viewModel.hasMore {
                    // 接近底部时加载更多
                    Color.clear
                        .frame(height: 1)
                        .onAppear {
                            Task {
                                await viewModel.loadMoreBooks()
                            }
                        }
                }
            }
            .padding()
        }
        .refreshable {
            await viewModel.refreshBooks()
        }
    }
    
    private var bookListView: some View {
        List {
            ForEach(viewModel.books, id: \.bookId) { book in
                if isSelecting {
                    Button {
                        toggleBookSelection(book)
                    } label: {
                        HStack {
                            Image(systemName: selectedBookIds.contains(book.bookId)
                                  ? "checkmark.circle.fill" : "circle")
                                .foregroundColor(selectedBookIds.contains(book.bookId) ? .accentColor : .secondary)

                            BookListItemView(book: book)
                        }
                    }
                    .buttonStyle(.plain)
                } else {
                    NavigationLink(destination: ReaderView(book: book)) {
                        BookListItemView(book: book)
                    }
                    .contextMenu {
                        Button {
                            changeSourceBook = book
                        } label: {
                            Label("换源", systemImage: "arrow.triangle.2.circlepath")
                        }

                        Button(role: .destructive) {
                            viewModel.removeBook(book)
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }
            }
            .onDelete { indexSet in
                if let index = indexSet.first {
                    viewModel.removeBook(viewModel.books[index])
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}

// MARK: - 网格项
struct BookGridItemView: View {
    let book: Book
    var showName: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 封面
            BookCoverView(url: book.coverUrl)
                .frame(maxWidth: .infinity)
                .aspectRatio(3/4, contentMode: .fill)
                .background(Color.gray.opacity(0.1))
                .cornerRadius(8)
                .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
                .overlay(alignment: .topTrailing) {
                    if book.unreadChapterCount > 0 {
                        Text("\(book.unreadChapterCount)")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.red))
                            .padding(4)
                    }
                }
            
            if showName {
                // 书名
                Text(book.name)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .foregroundColor(.primary)

                // 作者
                Text(book.author)
                    .font(.caption2)
                    .lineLimit(1)
                    .foregroundColor(.secondary)
            }
            
            // 进度条：Android 在「尚未开始阅读」时不显示
            if !book.hasNotStartedReading {
                ProgressView(value: book.readProgress)
                    .progressViewStyle(.linear)
                    .tint(.blue)
            }
        }
    }
}

// MARK: - 列表项
struct BookListItemView: View {
    let book: Book
    
    var body: some View {
        HStack(spacing: 12) {
            // 封面
            BookCoverView(url: book.coverUrl)
                .frame(width: 60, height: 80)
                .background(Color.gray.opacity(0.1))
                .cornerRadius(4)
            
            VStack(alignment: .leading, spacing: 4) {
                // 书名
                Text(book.name)
                    .font(.body)
                    .fontWeight(.medium)
                    .lineLimit(1)
                
                // 作者
                Text(book.author)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                
                // 当前阅读章节（Android tvRead）
                if let reading = book.durChapterTitle, !reading.isEmpty {
                    Text("读到：\(reading)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                // 最新章节
                if let chapter = book.latestChapterTitle {
                    Text(chapter)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                
                Spacer()
                
                // 进度：未开始阅读时不显示
                if !book.hasNotStartedReading {
                    HStack {
                        ProgressView(value: book.readProgress)
                            .progressViewStyle(.linear)
                            .frame(width: 100)

                        Text("\(Int(book.readProgress * 100))%")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

// MARK: - 封面视图
struct BookCoverView: View {
    let url: String?
    @State private var imageData: Data?
    
    var body: some View {
        Group {
            if let data = imageData, let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "books.vertical")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundColor(.gray.opacity(0.5))
            }
        }
        .task {
            if let urlString = url, !urlString.isEmpty {
                await loadImage(urlString: urlString)
            }
        }
    }
    
    private func loadImage(urlString: String) async {
        // 使用 ImageCacheManager 实现内存+磁盘缓存
        let cached = await ImageCacheManager.shared.loadImage(from: urlString)
        if let cached = cached {
            imageData = cached.pngData()
        }
    }
}

// MARK: - 空状态
struct EmptyStateView: View {
    let title: String
    let subtitle: String
    let imageName: String
    
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: imageName)
                .font(.system(size: 60))
                .foregroundColor(.gray.opacity(0.5))
            
            Text(title)
                .font(.title2)
                .fontWeight(.medium)
            
            Text(subtitle)
                .font(.body)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 预览
#Preview {
    BookshelfView()
}
