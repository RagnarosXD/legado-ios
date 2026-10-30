//
//  LogSettingsView.swift
//  Legado-iOS
//
//  运行日志：级别选择、文件列表、分享导出、清除
//

import SwiftUI
import UIKit

struct LogSettingsView: View {

    @AppStorage("logLevel") private var logLevelTitle: String = AppLogger.Level.debug.title
    @State private var files: [URL] = []
    @State private var shareItems: [Any] = []
    @State private var showingShare = false
    @State private var showingClearConfirm = false

    var body: some View {
        Form {
            Section {
                Picker("日志级别", selection: $logLevelTitle) {
                    ForEach(AppLogger.Level.allCases, id: \.title) { level in
                        Text(level.title).tag(level.title)
                    }
                }
                .onChange(of: logLevelTitle) { newValue in
                    if let level = AppLogger.Level.allCases.first(where: { $0.title == newValue }) {
                        AppLogger.minimumLevel = level
                    }
                    refresh()
                }
            } footer: {
                Text("级别越低记录越详细（调试会记录每条规则与请求）。崩溃日志始终记录，建议反馈问题时保持「调试」。")
            }

            Section("日志文件") {
                if files.isEmpty {
                    Text("暂无日志文件")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(files, id: \.self) { url in
                        Button {
                            share(url)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(url.lastPathComponent)
                                        .font(.subheadline)
                                        .foregroundColor(.primary)
                                    Text(sizeDescription(url))
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Image(systemName: "square.and.arrow.up")
                                    .foregroundColor(.blue)
                            }
                        }
                    }
                }
            }

            Section {
                Button(role: .destructive) {
                    showingClearConfirm = true
                } label: {
                    Text("清除全部日志")
                }

                Button {
                    share(files)
                } label: {
                    Text("分享全部日志（\(files.count) 个）")
                }
                .disabled(files.isEmpty)
            } footer: {
                Text("日志保存在 Documents/Logs 下，每次启动一个文件，文件名即启动时间。")
            }
        }
        .navigationTitle("运行日志")
        .navigationBarTitleDisplayMode(.inline)
        .task { refresh() }
        .onAppear { refresh() }
        .sheet(isPresented: $showingShare) {
            ActivityView(items: shareItems)
        }
        .alert("清除日志？", isPresented: $showingClearConfirm) {
            Button("清除", role: .destructive) {
                AppLogger.shared.deleteAllLogs()
                refresh()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会删除全部日志文件，包括崩溃记录，且不可恢复。")
        }
    }

    private func refresh() {
        files = AppLogger.shared.allLogFiles()
    }

    private func share(_ url: URL) {
        shareItems = [url]
        showingShare = true
    }

    private func share(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        shareItems = urls
        showingShare = true
    }

    private func sizeDescription(_ url: URL) -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        return String(format: "%.1f KB", Double(size) / 1024)
    }
}

/// UIActivityViewController 包装（ShareLink 在部分场景分享本地文件会失败）
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
