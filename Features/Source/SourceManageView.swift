//
//  SourceManageView.swift
//  Legado-iOS
//
//  书源管理界面（含批量操作）
//

import SwiftUI
import CoreData
import Foundation
import UniformTypeIdentifiers

struct SourceManageView: View {
    @StateObject private var viewModel = SourceViewModel()
    @State private var showingEdit = false
    @State private var showingImport = false
    @State private var editViewModel: SourceEditViewModel?
    
    // 批量操作状态
    @State private var isEditMode = false
    @State private var selectedSources: Set<UUID> = []

    // 批量校验
    @StateObject private var batch = SourceBatchController()
    @State private var showingCheckResults = false
    @AppStorage("searchConcurrency") private var concurrency: Int = 4
    
    @State private var showingExporter = false
    @State private var exportDocument = JSONDataDocument()
    @State private var exportFileName = "bookSource"

    // 筛选由 viewModel.activeFilter 驱动
    
    var body: some View {
        ZStack {
            List {
                if viewModel.sources.isEmpty {
                    EmptyStateView(
                        title: "暂无书源",
                        subtitle: "点击右上角导入或创建书源",
                        imageName: "square.grid.2x2"
                    )
                } else if filteredSources.isEmpty {
                    EmptyStateView(
                        title: "没有符合筛选的书源",
                        subtitle: "调整右上角筛选条件",
                        imageName: "line.3.horizontal.decrease.circle"
                    )
                } else {
                    // 按 bookSourceType 分类，不同类型不混排
                    sourceSection(.text)
                    sourceSection(.audio)
                    sourceSection(.image)
                    sourceSection(.file)
                }
            }
            .listStyle(.insetGrouped)
            .safeAreaInset(edge: .top, spacing: 0) {
                filterBar
            }
            .navigationTitle("书源管理")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $viewModel.searchText, prompt: "搜索名称 / 地址 / 分组")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(isEditMode ? "取消" : "编辑") {
                        withAnimation {
                            isEditMode.toggle()
                            if !isEditMode {
                                selectedSources.removeAll()
                            }
                        }
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 12) {
                        Menu {
                            Picker("排序", selection: $viewModel.sortBy) {
                                ForEach(SourceSortBy.allCases) { sort in
                                    Text(sort.title).tag(sort)
                                }
                            }
                            Divider()
                            Button {
                                inferTypes()
                            } label: {
                                Label("重新识别书源类型", systemImage: "wand.and.stars")
                            }
                        } label: {
                            Image(systemName: "line.3.horizontal.decrease.circle")
                        }

                        Menu {
                            Button(action: { showingImport = true }) {
                                Label("导入书源", systemImage: "square.and.arrow.down")
                            }
                            
                            Button(action: exportAllSources) {
                                Label("导出全部", systemImage: "square.and.arrow.up")
                            }

                            Button(action: exportSelectedSources) {
                                Label("导出选中（\(selectedSources.count)）", systemImage: "square.and.arrow.up.on.square")
                            }
                            .disabled(selectedSources.isEmpty)
                        } label: {
                            Image(systemName: "ellipsis")
                        }

                        Button(action: {
                            editViewModel = SourceEditViewModel()
                            showingEdit = true
                        }) {
                            Image(systemName: "plus")
                        }
                    }
                }
            }
            .sheet(isPresented: $showingEdit, onDismiss: {
                editViewModel = nil
                Task {
                    await viewModel.loadSources()
                }
            }) {
                if let editViewModel {
                    SourceEditView(viewModel: editViewModel)
                }
            }
            .sheet(isPresented: $showingImport) {
                SourceImportView(viewModel: viewModel)
            }
            .fileExporter(
                isPresented: $showingExporter,
                document: exportDocument,
                contentType: .json,
                defaultFilename: exportFileName
            ) { result in
                if case .failure(let error) = result {
                    viewModel.errorMessage = "导出失败：\(error.localizedDescription)"
                }
            }
            .task {
                await viewModel.loadSources()
            }
            .alert("操作失败", isPresented: Binding(
                get: { viewModel.errorMessage != nil },
                set: { if !$0 { viewModel.errorMessage = nil } }
            )) {
                Button("确定", role: .cancel) {
                    viewModel.errorMessage = nil
                }
            } message: {
                Text(viewModel.errorMessage ?? "未知错误")
            }
            .sheet(isPresented: $showingCheckResults) {
                SourceCheckSheet(batch: batch, sources: viewModel.sources)
            }

            // MARK: - 底部批量操作栏
            if isEditMode && !viewModel.sources.isEmpty {
                VStack {
                    Spacer()
                    
                    BatchActionBar(
                        selectedCount: selectedSources.count,
                        totalCount: viewModel.sources.count,
                        onSelectAll: selectAll,
                        onEnable: { batchEnable(true) },
                        onDisable: { batchEnable(false) },
                        onValidate: validateSelected,
                        onDelete: batchDelete
                    )
                }
            }

            // 校验进度
            if batch.isChecking {
                VStack(spacing: 10) {
                    ProgressView(value: batch.progress)
                        .frame(width: 180)
                    Text("校验中 \(batch.checkedCount)/\(batch.totalCount)")
                        .font(.caption)
                }
                .padding(18)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }
    
    // MARK: - 筛选与分组

    private var filteredSources: [BookSource] {
        viewModel.filteredSources
    }

    /// 顶部横向筛选条：文本 / 有声 / 漫画 / 文件 / 需登录 / 有发现 / 已停用
    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(SourceFilter.allCases) { filter in
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            viewModel.activeFilter = filter
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: filter.icon)
                                .font(.system(size: 10))
                            Text(filter.title)
                                .font(.caption)
                            Text("\(viewModel.count(for: filter))")
                                .font(.caption2)
                                .opacity(0.7)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            Capsule().fill(
                                viewModel.activeFilter == filter
                                    ? Color.accentColor.opacity(0.16)
                                    : Color(.secondarySystemBackground)
                            )
                        )
                        .overlay(
                            Capsule().stroke(
                                viewModel.activeFilter == filter ? Color.accentColor : Color.clear,
                                lineWidth: 1
                            )
                        )
                        .foregroundColor(viewModel.activeFilter == filter ? .accentColor : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }

    private func inferTypes() {
        let changed = viewModel.inferSourceTypes()
        if changed > 0 {
            Task { await viewModel.loadSources() }
        }
    }

    /// 按 bookSourceType 分组，不同类型互不混排
    @ViewBuilder
    private func sourceSection(_ section: SourceTypeSection) -> some View {
        let items = filteredSources.filter { $0.bookSourceType == section.rawValue }
        if !items.isEmpty {
            Section {
                ForEach(items, id: \.sourceId) { source in
                    sourceRow(source)
                }
            } header: {
                HStack {
                    Text(section.title)
                    Spacer()
                    Text("\(items.count)")
                }
            }
        }
    }

    @ViewBuilder
    private func sourceRow(_ source: BookSource) -> some View {
        SourceItemView(
            source: source,
            isSelected: selectedSources.contains(source.sourceId),
            isEditMode: isEditMode
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if isEditMode {
                toggleSelection(source.sourceId)
            }
        }
        .swipeActions {
            if !isEditMode {
                Button(role: .destructive) {
                    viewModel.deleteSource(source)
                } label: {
                    Label("删除", systemImage: "trash")
                }

                Button {
                    editViewModel = SourceEditViewModel(source: source)
                    showingEdit = true
                } label: {
                    Label("编辑", systemImage: "pencil")
                }
                .tint(.blue)
            }
        }
        // 长按菜单（对齐 Android BookSourceAdapter 的长按项）
        .contextMenu {
            Button {
                viewModel.moveToTop(source)
            } label: {
                Label("置顶", systemImage: "arrow.up.to.line")
            }

            Button {
                viewModel.moveToBottom(source)
            } label: {
                Label("置底", systemImage: "arrow.down.to.line")
            }

            Button {
                editViewModel = SourceEditViewModel(source: source)
                showingEdit = true
            } label: {
                Label("编辑", systemImage: "pencil")
            }

            if source.hasExplore {
                Button {
                    viewModel.toggleExplore(source)
                } label: {
                    Label(
                        source.enabledExplore ? "停用发现" : "启用发现",
                        systemImage: "safari"
                    )
                }
            }

            Divider()

            Button(role: .destructive) {
                viewModel.deleteSource(source)
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    // MARK: - 批量校验

    private func validateSelected() {
        let targets = viewModel.sources.filter { selectedSources.contains($0.sourceId) }
        guard !targets.isEmpty else { return }
        showingCheckResults = true
        Task {
            await batch.validate(targets, concurrency: concurrency)
        }
    }

    private func toggleSelection(_ id: UUID) {
        if selectedSources.contains(id) {
            selectedSources.remove(id)
        } else {
            selectedSources.insert(id)
        }
    }
    
    private func selectAll() {
        let visible = filteredSources
        if selectedSources.count == visible.count {
            selectedSources.removeAll()
        } else {
            selectedSources = Set(visible.map { $0.sourceId })
        }
    }
    
    private func batchEnable(_ enabled: Bool) {
        for id in selectedSources {
            if let source = viewModel.sources.first(where: { $0.sourceId == id }) {
                source.enabled = enabled
            }
        }
        try? CoreDataStack.shared.save()
        selectedSources.removeAll()
    }
    
    private func batchDelete() {
        // 一次性删除并保存，避免循环里反复 save / 刷新导致的失效对象访问
        viewModel.deleteSources(ids: selectedSources)
        selectedSources.removeAll()
    }

    private func exportAllSources() {
        guard let data = viewModel.exportSources() else { return }
        exportDocument = JSONDataDocument(data: data)
        exportFileName = makeExportFileName()
        showingExporter = true
    }

    private func exportSelectedSources() {
        guard !selectedSources.isEmpty,
              let data = viewModel.exportSources(ids: selectedSources) else { return }
        exportDocument = JSONDataDocument(data: data)
        exportFileName = makeExportFileName()
        showingExporter = true
    }

    private func makeExportFileName() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "bookSource-\(formatter.string(from: Date()))"
    }
}

// MARK: - 批量操作栏
struct BatchActionBar: View {
    let selectedCount: Int
    let totalCount: Int
    let onSelectAll: () -> Void
    let onEnable: () -> Void
    let onDisable: () -> Void
    let onValidate: () -> Void
    let onDelete: () -> Void
    
    var body: some View {
        HStack(spacing: 0) {
            // 选择状态
            Button(action: onSelectAll) {
                VStack(spacing: 2) {
                    Image(systemName: selectedCount == totalCount ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                    Text(selectedCount == totalCount ? "取消全选" : "全选")
                        .font(.caption2)
                }
                .frame(maxWidth: .infinity)
            }
            
            Divider()
                .frame(height: 40)
            
            // 启用
            Button(action: onEnable) {
                VStack(spacing: 2) {
                    Image(systemName: "checkmark.circle")
                        .font(.title3)
                    Text("启用")
                        .font(.caption2)
                }
                .frame(maxWidth: .infinity)
            }
            .disabled(selectedCount == 0)
            .opacity(selectedCount == 0 ? 0.5 : 1)
            
            Divider()
                .frame(height: 40)
            
            // 禁用
            Button(action: onDisable) {
                VStack(spacing: 2) {
                    Image(systemName: "xmark.circle")
                        .font(.title3)
                    Text("禁用")
                        .font(.caption2)
                }
                .frame(maxWidth: .infinity)
            }
            .disabled(selectedCount == 0)
            .opacity(selectedCount == 0 ? 0.5 : 1)

            Divider()
                .frame(height: 40)

            // 校验
            Button(action: onValidate) {
                VStack(spacing: 2) {
                    Image(systemName: "checkmark.shield")
                        .font(.title3)
                    Text("校验")
                        .font(.caption2)
                }
                .frame(maxWidth: .infinity)
            }
            .disabled(selectedCount == 0)
            .opacity(selectedCount == 0 ? 0.5 : 1)

            Divider()
                .frame(height: 40)

            // 删除
            Button(action: onDelete) {
                VStack(spacing: 2) {
                    Image(systemName: "trash")
                        .font(.title3)
                    Text("删除")
                        .font(.caption2)
                }
                .frame(maxWidth: .infinity)
                .foregroundColor(.red)
            }
            .disabled(selectedCount == 0)
            .opacity(selectedCount == 0 ? 0.5 : 1)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 8)
        .background(.ultraThinMaterial)
    }
}

// MARK: - 书源列表项（增强版）
struct SourceItemView: View {
    let source: BookSource
    var isSelected: Bool = false
    var isEditMode: Bool = false
    
    var body: some View {
        HStack(spacing: 12) {
            // 编辑模式下的选择指示器
            if isEditMode {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isSelected ? .blue : .gray)
                    .font(.title3)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(source.bookSourceName)
                        .font(.body)
                        .fontWeight(.medium)
                    
                    Spacer()
                    
                    // 状态指示
                    Circle()
                        .fill(source.enabled ? Color.green : Color.gray)
                        .frame(width: 8, height: 8)
                    
                    // 类型图标
                    if source.isAudio {
                        Image(systemName: "headphones")
                            .font(.caption)
                            .foregroundColor(.blue)
                    } else if source.isImage {
                        Image(systemName: "photo")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }

                    // 能力标记：需登录 / 有发现
                    if source.requiresLogin {
                        Image(systemName: "person.badge.key")
                            .font(.caption)
                            .foregroundColor(.purple)
                    }
                    if source.hasExplore {
                        Image(systemName: "safari")
                            .font(.caption)
                            .foregroundColor(.teal)
                    }
                }
                
                if let group = source.bookSourceGroup {
                    Text(group)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                HStack {
                    Text("响应：\(source.respondTime / 1000)s")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    
                    Spacer()
                    
                    Text(source.bookSourceUrl)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

// MARK: - 书源导入界面
struct SourceImportView: View {
    @ObservedObject var viewModel: SourceViewModel
    @Environment(\.dismiss) var dismiss
    
    @State private var importText = ""
    @State private var importURL = ""
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("从 URL 导入")) {
                    TextField("书源 URL", text: $importURL)
                        .autocapitalization(.none)
                        .keyboardType(.URL)
                    
                    Button(action: {
                        Task {
                            let count = await viewModel.importFromURL(importURL)
                            if count > 0 {
                                dismiss()
                            }
                        }
                    }) {
                        Text("导入")
                    }
                    .disabled(importURL.isEmpty)
                }
                
                Section(header: Text("从文本导入")) {
                    TextEditor(text: $importText)
                        .frame(minHeight: 200)
                        .font(.system(.caption, design: .monospaced))
                    
                    Button(action: {
                        let count = viewModel.importFromText(importText)
                        if count > 0 {
                            dismiss()
                        }
                    }) {
                        Text("导入")
                    }
                    .disabled(importText.isEmpty)
                }
                
                Section {
                    Text("支持 JSON 格式的书源文件，可以复制书源链接或粘贴书源 JSON 内容")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("导入书源")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") {
                        dismiss()
                    }
                }
            }
        }
    }
}

#Preview {
    SourceManageView()
}

#Preview {
    SourceManageView()
}


// MARK: - 书源类型分组

enum SourceTypeSection: Int32, CaseIterable {
    case text = 0
    case audio = 1
    case image = 2
    case file = 3

    var title: String {
        switch self {
        case .text: return "文本"
        case .audio: return "有声"
        case .image: return "漫画"
        case .file: return "文件"
        }
    }
}
