//
//  MainTabView.swift
//  Legado-iOS
//
//  主 Tab 视图（完善版）
//

import SwiftUI
import Network
import UniformTypeIdentifiers

struct MainTabView: View {
    @State private var selectedTab = 0
    
    var body: some View {
        TabView(selection: $selectedTab) {
            // 书架（含本地书籍入口）
            NavigationStack { BookshelfView() }
                .tabItem {
                    Image(systemName: "books.vertical.fill")
                }
                .tag(0)
            
            // 发现（对齐 Android 的发现页）
            NavigationStack { ExploreView() }
                .tabItem {
                    Image(systemName: "safari.fill")
                }
                .tag(1)

            // 我的
            SettingsView()
                .tabItem {
                    Image(systemName: "person.crop.circle")
                }
                .tag(2)
        }
        .accentColor(.blue)
    }
}

// MARK: - 设置视图（完善版）
struct SettingsView: View {
    @State private var showingAbout = false
    @State private var showingQRScanner = false
    
    var body: some View {
        NavigationView {
            List {
                // 阅读设置
                Section(header: Label("阅读", systemImage: "book")) {
                    NavigationLink("阅读设置") {
                        ReaderSettingsFullView()
                    }
                    
                    NavigationLink("替换规则") {
                        ReplaceRuleView()
                    }
                    
                    NavigationLink("主题") {
                        ThemeSettingsView()
                    }
                }
                
                // 数据管理
                Section(header: Label("数据", systemImage: "database")) {
                    NavigationLink("备份与恢复") {
                        BackupRestoreView()
                    }

                    NavigationLink("阅读统计") {
                        ReadingStatisticsView()
                    }

                    NavigationLink("数据迁移") {
                        DataMigrationView()
                    }
                    
                    NavigationLink("词典规则") {
                        DictRuleView()
                    }
                    
                    NavigationLink("清理缓存") {
                        CacheCleanView()
                    }
                }
                
                // 书源管理
                Section(header: Label("书源", systemImage: "square.grid.2x2")) {
                    NavigationLink("书源管理") {
                        SourceManageView()
                    }

                    NavigationLink("书源订阅") {
                        SourceSubscriptionView()
                    }

                    NavigationLink("书源调试") {
                        SourceDebugView(viewModel: SourceDebugViewModel(source: nil))
                    }
                    
                    Button(action: { showingQRScanner = true }) {
                        HStack {
                            Text("扫码导入书源")
                            Spacer()
                            Image(systemName: "qrcode.viewfinder")
                                .foregroundColor(.secondary)
                        }
                    }
                }

                // 搜索
                Section(header: Label("搜索", systemImage: "magnifyingglass")) {
                    NavigationLink("搜索设置") {
                        SearchSettingsView()
                    }
                }

                // 诊断
                Section(header: Label("诊断", systemImage: "ladybug")) {
                    NavigationLink("运行日志") {
                        LogSettingsView()
                    }

                    Text("闪退后重新打开 App，在「运行日志」里点最新文件分享即可定位问题；可在同一页面调整日志级别或清除日志。")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                // 关于
                Section(header: Label("关于", systemImage: "info.circle")) {
                    HStack {
                        Text("版本")
                        Spacer()
                        Text(AppLogger.appVersion)
                            .foregroundColor(.secondary)
                    }
                    
                    Link("开源地址", destination: URL(string: "https://github.com/chrn11/legado-ios")!)
                    
                    Link("帮助文档", destination: URL(string: "https://www.legado.top/")!)
                    
                    Button("免责声明") {
                        showingAbout = true
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("我的")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showingAbout) {
                AboutView()
            }
            .sheet(isPresented: $showingQRScanner) {
                QRCodeScanView()
            }
        }
    }
}

// MARK: - 关于视图
struct AboutView: View {
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // 应用图标
                    Image(systemName: "books.vertical")
                        .font(.system(size: 80))
                        .foregroundColor(.blue)
                    
                    Text("Legado iOS")
                        .font(.title)
                        .fontWeight(.bold)
                    
                    Text("版本 1.0.0 (Alpha)")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    
                    Divider()
                    
                    // 简介
                    AboutSectionCard(title: "应用简介") {
                        Text("""
                        Legado iOS 是基于 Android 版 Legado（开源阅读）开发的 iOS 原生阅读应用。
                        
                        本应用支持自定义书源规则，可以解析网页内容，为广大网络文学爱好者提供一种方便、快捷、舒适的阅读体验。
                        """)
                    }
                    
                    // 特性
                    AboutSectionCard(title: "主要特性") {
                        VStack(alignment: .leading, spacing: 8) {
                            FeatureRow(icon: "square.grid.2x2", text: "自定义书源规则")
                            FeatureRow(icon: "magnifyingglass", text: "多书源聚合搜索")
                            FeatureRow(icon: "books.vertical", text: "本地 TXT/EPUB 支持")
                            FeatureRow(icon: "text.badge.checkmark", text: "内容替换净化")
                            FeatureRow(icon: "gearshape", text: "高度定制化阅读")
                        }
                    }
                    
                    // 技术栈
                    AboutSectionCard(title: "技术栈") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("• Swift 5.10+")
                            Text("• SwiftUI")
                            Text("• CoreData")
                            Text("• MVVM 架构")
                        }
                        .font(.caption)
                        .foregroundColor(.secondary)
                    }
                    
                    // 链接
                    AboutSectionCard(title: "相关链接") {
                        VStack(alignment: .leading, spacing: 8) {
                            Link("GitHub 仓库", destination: URL(string: "https://github.com/chrn11/legado-ios")!)
                                .foregroundColor(.blue)
                            
                            Link("Android 原版", destination: URL(string: "https://github.com/gedoor/legado")!)
                                .foregroundColor(.blue)
                            
                            Link("帮助文档", destination: URL(string: "https://www.legado.top/")!)
                                .foregroundColor(.blue)
                        }
                    }
                    
                    // 开源协议
                    AboutSectionCard(title: "开源协议") {
                        Text("本项目遵循 GPL-3.0 协议。")
                            .font(.caption)
                    }
                    
                    // 免责声明
                    AboutSectionCard(title: "免责声明") {
                        Text("""
                        本应用仅供学习交流使用，请勿用于商业目的。
                        
                        使用本应用时请遵守相关法律法规，尊重版权。
                        应用本身不提供任何内容，所有内容由书源提供。
                        """)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                }
                .padding()
            }
            .navigationTitle("关于")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - 辅助视图
struct FeatureRow: View {
    let icon: String
    let text: String
    
    var body: some View {
        HStack {
            Image(systemName: icon)
                .frame(width: 24)
                .foregroundColor(.blue)
            
            Text(text)
                .font(.body)
        }
    }
}

struct AboutSectionCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .foregroundColor(.primary)
            
            content
        }
        .padding()
        .background(Color.gray.opacity(0.05))
        .cornerRadius(8)
    }
}

// MARK: - 主题设置视图
struct ThemeSettingsView: View {
    @AppStorage("app_theme") private var selectedTheme = "system"
    
    var body: some View {
        List {
            Section("外观模式") {
                ForEach([
                    ("system", "跟随系统", "iphone"),
                    ("light", "浅色模式", "sun.max"),
                    ("dark", "深色模式", "moon")
                ], id: \.0) { (value, label, icon) in
                    Button(action: { selectedTheme = value }) {
                        HStack {
                            Image(systemName: icon)
                                .frame(width: 24)
                                .foregroundColor(.blue)
                            Text(label)
                                .foregroundColor(.primary)
                            Spacer()
                            if selectedTheme == value {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.blue)
                            }
                        }
                    }
                }
            }
            
            Section("阅读背景") {
                ForEach([
                    ("白色", Color.white),
                    ("米黄", Color(red: 0.98, green: 0.95, blue: 0.88)),
                    ("浅绿", Color(red: 0.8, green: 0.93, blue: 0.8)),
                    ("深灰", Color(white: 0.2))
                ], id: \.0) { (name, color) in
                    HStack {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(color)
                            .frame(width: 40, height: 30)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(Color.gray.opacity(0.3), lineWidth: 1)
                            )
                        Text(name)
                        Spacer()
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("主题")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 缓存清理视图
struct CacheCleanView: View {
    @State private var imageCacheSize: String = "计算中..."
    @State private var chapterCacheSize: String = "计算中..."
    @State private var isClearing = false
    @State private var showingAlert = false
    @State private var alertMessage = ""

    // 自动缓存策略（对齐 Android 缓存设置）
    @AppStorage("cachePreloadCount") private var preloadCount: Int = 3
    @AppStorage("cacheWiFiOnly") private var wifiOnly: Bool = false
    @AppStorage("cacheLimitMB") private var cacheLimitMB: Int = 500

    var body: some View {
        List {
            Section("自动缓存") {
                Stepper(
                    "预下载章节：前后各 \(preloadCount) 章",
                    value: $preloadCount,
                    in: 0...10
                )

                Toggle("仅在 Wi-Fi 下缓存", isOn: $wifiOnly)

                Stepper(
                    cacheLimitMB == 0 ? "缓存上限：不限" : "缓存上限：\(cacheLimitMB) MB",
                    value: $cacheLimitMB,
                    in: 0...5000,
                    step: 100
                )
            }

            Section("缓存占用") {
                HStack {
                    Label("图片缓存", systemImage: "photo")
                    Spacer()
                    Text(imageCacheSize)
                        .foregroundColor(.secondary)
                }
                HStack {
                    Label("章节缓存", systemImage: "doc.text")
                    Spacer()
                    Text(chapterCacheSize)
                        .foregroundColor(.secondary)
                }
            }
            
            Section {
                Button(action: { clearImageCache() }) {
                    HStack {
                        Image(systemName: "trash")
                        Text("清理图片缓存")
                    }
                }
                
                Button(action: { clearChapterCache() }) {
                    HStack {
                        Image(systemName: "trash")
                        Text("清理章节缓存")
                    }
                }
                
                Button(role: .destructive, action: clearAll) {
                    HStack {
                        Image(systemName: "trash")
                        Text("清理全部缓存")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("清理缓存")
        .navigationBarTitleDisplayMode(.inline)
        .task { calculateCacheSize() }
        .alert("提示", isPresented: $showingAlert) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
    }
    
    private func calculateCacheSize() {
        imageCacheSize = folderSize(imageCacheDir())
        chapterCacheSize = folderSize(chapterCacheDir())
    }

    private func imageCacheDir() -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("images", isDirectory: true)
    }

    private func chapterCacheDir() -> URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("chapters", isDirectory: true)
    }
    
    private func folderSize(_ url: URL?) -> String {
        guard let url = url else { return "0 B" }
        let fm = FileManager.default
        var total: Int64 = 0
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else {
            return "0 B"
        }

        for case let itemURL as URL in enumerator {
            guard let values = try? itemURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]) else { continue }
            guard values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }
    
    private func clearImageCache(showMessage: Bool = true) {
        let dir = imageCacheDir()
        clearDir(dir)
        ImageCacheManager.shared.clearCache()
        calculateCacheSize()

        if showMessage {
            alertMessage = "图片缓存已清理"
            showingAlert = true
        }
    }
    
    private func clearChapterCache(showMessage: Bool = true) {
        let dir = chapterCacheDir()
        clearDir(dir)
        calculateCacheSize()

        if showMessage {
            alertMessage = "章节缓存已清理"
            showingAlert = true
        }
    }
    
    private func clearAll() {
        isClearing = true
        defer { isClearing = false }

        clearImageCache(showMessage: false)
        clearChapterCache(showMessage: false)
        alertMessage = "全部缓存已清理"
        showingAlert = true
    }
    
    private func clearDir(_ url: URL?) {
        guard let url = url else { return }
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}

struct DataMigrationView: View {
    @StateObject private var manager = DataMigrationManager()
    @State private var selectedType: MigrationType = .legadoAndroid
    @State private var showingImporter = false

    @State private var includeBooks = true
    @State private var includeSources = true
    @State private var includeBookmarks = true
    @State private var includeRules = true
    @State private var showingExporter = false
    @State private var exportDocument = JSONDataDocument()

    var body: some View {
        List {
            Section("导入") {
                Picker("类型", selection: $selectedType) {
                    ForEach(MigrationType.allCases, id: \.self) { type in
                        Text(type.displayName).tag(type)
                    }
                }

                Button("选择文件导入") {
                    showingImporter = true
                }
                .disabled(manager.isMigrating)

                if manager.isMigrating {
                    ProgressView(value: manager.migrationProgress)
                }
            }

            Section("导出") {
                Toggle("包含书籍", isOn: $includeBooks)
                Toggle("包含书源", isOn: $includeSources)
                Toggle("包含书签", isOn: $includeBookmarks)
                Toggle("包含替换规则", isOn: $includeRules)

                Button("导出备份") {
                    exportBackup()
                }
            }

            if let result = manager.migrationResult {
                Section("结果") {
                    Text(result.summary)

                    if !result.errors.isEmpty {
                        Text("错误：")
                            .font(.headline)
                        ForEach(result.errors, id: \.self) { err in
                            Text(err)
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                    }
                }
            }
        }
        .navigationTitle("数据迁移")
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.json, .zip, .plainText, .data],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                Task { @MainActor in
                    let granted = url.startAccessingSecurityScopedResource()
                    defer {
                        if granted {
                            url.stopAccessingSecurityScopedResource()
                        }
                    }
                    _ = await manager.migrateFromFile(url, type: selectedType)
                }
            case .failure:
                break
            }
        }
        .fileExporter(
            isPresented: $showingExporter,
            document: exportDocument,
            contentType: .json,
            defaultFilename: "legado-ios-backup"
        ) { _ in }
    }

    private func exportBackup() {
        guard let data = manager.exportData(
            includeBooks: includeBooks,
            includeSources: includeSources,
            includeBookmarks: includeBookmarks,
            includeRules: includeRules
        ) else {
            return
        }

        exportDocument = JSONDataDocument(data: data)
        showingExporter = true
    }
}

struct JSONDataDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    var data: Data

    init(data: Data = Data()) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct SourceSubscriptionView: View {
    @StateObject private var manager = SourceSubscriptionManager()
    @State private var showingAdd = false
    @State private var newName = ""
    @State private var newUrl = ""

    var body: some View {
        List {
            Section {
                if manager.subscriptions.isEmpty {
                    Text("暂无订阅")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(manager.subscriptions) { sub in
                        subscriptionRow(sub)
                    }
                    .onDelete { indexSet in
                        if let index = indexSet.first {
                            manager.removeSubscription(at: index)
                        }
                    }
                }
            } header: {
                Text("订阅列表")
            }

            Section("操作") {
                Button("更新所有订阅") {
                    Task { @MainActor in
                        await manager.updateAllSubscriptions()
                    }
                }

                if manager.isUpdating {
                    ProgressView(value: manager.updateProgress)
                }

                if let err = manager.lastUpdateError {
                    Text(err)
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }
        }
        .navigationTitle("书源订阅")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showingAdd = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .alert("添加订阅", isPresented: $showingAdd) {
            TextField("名称", text: $newName)
            TextField("订阅 URL", text: $newUrl)
                .textInputAutocapitalization(.never)
            Button("取消", role: .cancel) {
                newName = ""
                newUrl = ""
            }
            Button("添加") {
                let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                let url = newUrl.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty, !url.isEmpty {
                    manager.addSubscription(name: name, url: url)
                }
                newName = ""
                newUrl = ""
            }
        }
    }

    @ViewBuilder
    private func subscriptionRow(_ sub: SourceSubscription) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(sub.name)
                    .font(.headline)

                Spacer()

                Toggle("", isOn: Binding(
                    get: { sub.enabled },
                    set: { newValue in
                        var updated = sub
                        updated.enabled = newValue
                        manager.updateSubscription(updated)
                    }
                ))
                .labelsHidden()
            }

            Text(sub.url)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)

            HStack(spacing: 8) {
                Toggle("自动更新", isOn: Binding(
                    get: { sub.autoUpdate },
                    set: { newValue in
                        var updated = sub
                        updated.autoUpdate = newValue
                        manager.updateSubscription(updated)
                    }
                ))
                .font(.caption)

                Spacer()

                if let last = sub.lastUpdateTime {
                    Text("上次：\(last.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                } else {
                    Text("从未更新")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            HStack {
                Button("立即更新") {
                    Task { @MainActor in
                        try? await manager.updateSubscription(id: sub.id)
                    }
                }
                .font(.caption)

                Spacer()

                Menu {
                    ForEach([3600.0, 21600.0, 43200.0, 86400.0, 172800.0], id: \.self) { seconds in
                        Button("每 \(Int(seconds / 3600)) 小时") {
                            var updated = sub
                            updated.updateInterval = seconds
                            manager.updateSubscription(updated)
                        }
                    }
                } label: {
                    Text("间隔：\(Int(sub.updateInterval / 3600))h")
                        .font(.caption)
                        .foregroundColor(.blue)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    MainTabView()
}

// ===== 发现页（对齐 Android ExploreFragment / ExploreShowActivity）=====
//
//  ExploreView.swift
//  Legado-iOS
//
//  发现页 — 对齐 Android ExploreFragment / ExploreShowActivity
//

import SwiftUI
import CoreData

// MARK: - 发现首页（书源列表）

struct ExploreView: View {

    @StateObject private var viewModel = ExploreViewModel()
    @State private var keyword = ""
    @State private var selectedKind: ExploreKindSelection?

    var body: some View {
        List {
            if viewModel.sources.isEmpty {
                EmptyStateView(
                    title: "没有可用的发现页",
                    subtitle: "在书源管理中检查「有发现」的书源",
                    imageName: "safari"
                )
            } else {
                ForEach(viewModel.sources, id: \.sourceId) { source in
                    ExploreSourceRow(source: source) { kind in
                        selectedKind = ExploreKindSelection(source: source, kind: kind)
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("发现")
        .searchable(text: $keyword, prompt: "搜索书源或分类")
        .onChange(of: keyword) { value in
            viewModel.filter = value
        }
        .task {
            viewModel.loadSources()
        }
        .sheet(item: $selectedKind) { selection in
            NavigationView {
                ExploreListView(source: selection.source, kind: selection.kind)
            }
        }
    }
}

// MARK: - 分类选择

struct ExploreKindSelection: Identifiable {
    let source: BookSource
    let kind: BookSource.ExploreKindItem

    var id: String { "\(source.sourceId.uuidString)-\(kind.name)" }
}

// MARK: - 书源行（可展开分类 chips）

private struct ExploreSourceRow: View {

    let source: BookSource
    let onSelect: (BookSource.ExploreKindItem) -> Void

    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    expanded.toggle()
                }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(source.bookSourceName)
                            .font(.body)
                            .foregroundColor(.primary)

                        if let group = source.bookSourceGroup, !group.isEmpty {
                            Text(group)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }

                    Spacer()

                    Text("\(source.exploreKinds.count)")
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .buttonStyle(.plain)

            if expanded {
                let kinds = source.exploreKinds
                if kinds.isEmpty {
                    Text("该源的 exploreUrl 需要 JS 生成，暂不支持")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                } else {
                    FlowLayout(spacing: 6) {
                        ForEach(kinds) { kind in
                            Button {
                                onSelect(kind)
                            } label: {
                                Text(kind.name)
                                    .font(.caption)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Capsule().fill(Color(.secondarySystemBackground)))
                                    .foregroundColor(.primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - 分类内容页

struct ExploreListView: View {

    let source: BookSource
    let kind: BookSource.ExploreKindItem

    @StateObject private var viewModel = ExploreListViewModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            ForEach(viewModel.results, id: \.bookUrl) { result in
                Button {
                    Task { await viewModel.addToShelf(result: result) }
                } label: {
                    ExploreResultRow(result: result)
                }
                .buttonStyle(.plain)
            }

            if viewModel.isLoading {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            } else if viewModel.hasMore {
                Button("加载下一页") {
                    Task { await viewModel.loadMore() }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .listStyle(.plain)
        .navigationTitle(kind.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button("关闭") { dismiss() }
            }
        }
        .task {
            await viewModel.load(source: source, ruleUrl: kind.url)
        }
        .alert("提示", isPresented: $viewModel.showingAlert) {
            Button("好的") { }
        } message: {
            Text(viewModel.alertMessage)
        }
    }
}

// MARK: - 结果行

private struct ExploreResultRow: View {

    let result: SearchBookResult

    var body: some View {
        HStack(spacing: 10) {
            BookCoverView(url: result.coverUrl)
                .frame(width: 48, height: 64)
                .background(Color.gray.opacity(0.1))
                .cornerRadius(4)

            VStack(alignment: .leading, spacing: 3) {
                Text(result.name)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)

                if !result.author.isEmpty {
                    Text(result.author)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                if let last = result.lastChapter, !last.isEmpty {
                    Text(last)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 简易流式布局（分类 chips 换行）

struct FlowLayout: Layout {

    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var currentWidth: CGFloat = 0
        var totalHeight: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentWidth + size.width > maxWidth, currentWidth > 0 {
                totalHeight += rowHeight + spacing
                currentWidth = 0
                rowHeight = 0
            }
            currentWidth += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }

        totalHeight += rowHeight
        return CGSize(width: maxWidth.isFinite ? maxWidth : currentWidth, height: max(totalHeight, 0))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

//
//  ExploreViewModel.swift
//  Legado-iOS
//
//  发现页数据层
//

import Foundation
import CoreData

// MARK: - 发现首页

@MainActor
final class ExploreViewModel: ObservableObject {

    @Published var sources: [BookSource] = []
    @Published var filter: String = ""

    private var allSources: [BookSource] = []

    func loadSources() {
        let request: NSFetchRequest<BookSource> = BookSource.fetchRequest()
        request.predicate = NSPredicate(format: "enabled == YES")
        request.sortDescriptors = [NSSortDescriptor(key: "customOrder", ascending: true)]

        let fetched = (try? CoreDataStack.shared.viewContext.fetch(request)) ?? []
        allSources = fetched.filter { !$0.exploreKinds.isEmpty }
        applyFilter()
    }

    private func applyFilter() {
        let keyword = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !keyword.isEmpty else {
            sources = allSources
            return
        }

        sources = allSources.filter { source in
            if source.bookSourceName.lowercased().contains(keyword) { return true }
            if (source.bookSourceGroup ?? "").lowercased().contains(keyword) { return true }
            return source.exploreKinds.contains { $0.name.lowercased().contains(keyword) }
        }
    }
}

// MARK: - 分类内容页

@MainActor
final class ExploreListViewModel: ObservableObject {

    @Published var results: [SearchBookResult] = []
    @Published var isLoading = false
    @Published var hasMore = true
    @Published var showingAlert = false
    @Published var alertMessage = ""

    private var source: BookSource?
    private var ruleUrl: String = ""
    private var page = 1
    private var loaded = Set<String>()

    func load(source: BookSource, ruleUrl: String) async {
        self.source = source
        self.ruleUrl = ruleUrl
        page = 1
        results = []
        loaded = []
        hasMore = true
        await fetch()
    }

    func loadMore() async {
        guard hasMore, !isLoading else { return }
        page += 1
        await fetch()
    }

    private func fetch() async {
        guard let source, !ruleUrl.isEmpty else { return }

        isLoading = true
        defer { isLoading = false }

        do {
            let books = try await WebBook.exploreBook(source: source, ruleUrl: ruleUrl, page: page)

            var added = 0
            for book in books where !book.bookUrl.isEmpty {
                if loaded.insert(book.bookUrl).inserted {
                    results.append(book)
                    added += 1
                }
            }

            // 与 Android 一致：新一页没有新增条目则视为没有更多
            hasMore = added > 0
            AppLogger.info("Explore", "分类 \(ruleUrl.prefix(60)) page=\(page) 新增=\(added) 累计=\(results.count)")
        } catch {
            hasMore = false
            alertMessage = "加载失败：\(error.localizedDescription)"
            showingAlert = true
        }
    }

    /// 加入书架（复用搜索的入库规则：按 bookUrl 去重）
    func addToShelf(result: SearchBookResult) async {
        let context = CoreDataStack.shared.viewContext

        let request: NSFetchRequest<Book> = Book.fetchRequest()
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "bookUrl == %@", result.bookUrl)

        if let existing = try? context.fetch(request).first {
            existing.name = result.name
            existing.author = result.author
            existing.coverUrl = result.coverUrl
            existing.intro = result.intro
            existing.originName = result.sourceName
            existing.updatedAt = Date()
            try? CoreDataStack.shared.save()
            alertMessage = "《\(existing.name)》已在书架"
            showingAlert = true
            return
        }

        guard let source else { return }

        let book = Book.create(in: context)
        book.name = result.name
        book.author = result.author
        book.coverUrl = result.coverUrl
        book.intro = result.intro
        book.bookUrl = result.bookUrl
        book.tocUrl = ""
        book.origin = source.sourceId.uuidString
        book.originName = source.bookSourceName
        book.source = source
        try? context.save()

        alertMessage = "已加入书架"
        showingAlert = true
    }
}

// MARK: - 网络状态

/// 简单的网络状态观察（Wi-Fi 判断用于「仅 Wi-Fi 缓存」与离线提示）
final class NetworkMonitor {
    static let shared = NetworkMonitor()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.legado.network.monitor")

    private(set) var isConnected = true
    private(set) var isWiFi = true

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.isConnected = path.status == .satisfied
            self?.isWiFi = path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet)
        }
        monitor.start(queue: queue)
    }
}
