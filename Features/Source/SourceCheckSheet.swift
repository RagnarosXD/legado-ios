//
//  SourceCheckSheet.swift
//  Legado-iOS
//
//  批量校验结果：汇总 + 明细 + 一键停用失败源
//

import SwiftUI

struct SourceCheckSheet: View {
    @ObservedObject var batch: SourceBatchController
    let sources: [BookSource]

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                if batch.isChecking {
                    Section {
                        ProgressView(value: batch.progress)
                        Text("校验中 \(batch.checkedCount)/\(batch.totalCount)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } header: {
                        Text("进度")
                    }
                }

                if batch.outcomes.isEmpty && !batch.isChecking {
                    EmptyStateView(
                        title: "没有校验结果",
                        subtitle: "选择书源后点击「校验」",
                        imageName: "checkmark.shield"
                    )
                } else {
                    Section("汇总") {
                        HStack {
                            Text("可用")
                            Spacer()
                            Text("\(batch.successCount)")
                                .foregroundColor(.green)
                        }
                        HStack {
                            Text("失败")
                            Spacer()
                            Text("\(batch.failureCount)")
                                .foregroundColor(.red)
                        }
                    }

                    Section("明细") {
                        ForEach(batch.outcomes) { outcome in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Image(systemName: outcome.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                                        .foregroundColor(outcome.success ? .green : .red)
                                        .font(.caption)

                                    Text(outcome.name)
                                        .font(.subheadline)
                                        .lineLimit(1)

                                    Spacer()

                                    Text("\(outcome.cost)ms")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }

                                Text("\(outcome.typeName) · \(outcome.message)")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 2)
                        }
                    }

                    Section {
                        Button {
                            batch.disableFailed(in: sources)
                            dismiss()
                        } label: {
                            Text("停用 \(batch.failureCount) 个失败书源")
                        }
                        .disabled(batch.failureCount == 0 || batch.isChecking)
                    } footer: {
                        Text("校验会用 checkKeyWord（缺省「我的」）对每个源跑一次真实搜索；有声/漫画源只测站点可达。")
                    }
                }
            }
            .navigationTitle("书源校验")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
