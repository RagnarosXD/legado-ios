import SwiftUI
import UIKit

struct SourceEditView: View {
    @ObservedObject var viewModel: SourceEditViewModel
    @Environment(\.dismiss) var dismiss

    /// 把当前编辑内容序列化为 JSON 并复制（对齐 Android 编辑页的「复制」）
    private func copyJSONToPasteboard() {
        let json = viewModel.exportJSON()
        guard !json.isEmpty else { return }
        UIPasteboard.general.string = json
    }

    var body: some View {
        NavigationView {
            Form {
                BasicInfoSection(viewModel: viewModel)
                SearchRuleSection(viewModel: viewModel)
                ExploreRuleSection(viewModel: viewModel)
                BookInfoRuleSection(viewModel: viewModel)
                TocRuleSection(viewModel: viewModel)
                ContentRuleSection(viewModel: viewModel)
                ReviewRuleSection(viewModel: viewModel)
            }
            .navigationTitle(viewModel.isNewSource ? "新书源" : "编辑书源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Menu {
                        Button("保存") {
                            viewModel.save()
                        }

                        // 对齐 Android 编辑页的「复制」：把当前编辑内容序列化成 JSON
                        Button {
                            copyJSONToPasteboard()
                        } label: {
                            Label("复制书源 JSON", systemImage: "doc.on.doc")
                        }
                    } label: {
                        Text("保存")
                    }
                }
            }
        }
        .onChange(of: viewModel.didSave) { saved in
            if saved {
                dismiss()
            }
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
    }
}

// MARK: - 段评规则

struct ReviewRuleSection: View {
    @ObservedObject var viewModel: SourceEditViewModel

    var body: some View {
        Section("段评规则") {
            TextEditor(text: $viewModel.reviewRule)
                .font(.system(.caption, design: .monospaced))
                .frame(minHeight: 88)
                .overlay(alignment: .topLeading) {
                    if viewModel.reviewRule.isEmpty {
                        Text(#"{"reviewList":"","avatarRule":"","contentRule":""}"#)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .padding(.top, 8)
                            .padding(.leading, 4)
                            .allowsHitTesting(false)
                    }
                }
        }
    }
}
