//
//  SearchSettingsView.swift
//  Legado-iOS
//
//  搜索设置：并发数（书源校验复用同一设置）
//

import SwiftUI

struct SearchSettingsView: View {
    @AppStorage("searchConcurrency") private var concurrency: Int = 4

    var body: some View {
        Form {
            Section {
                Stepper(value: $concurrency, in: 1...8) {
                    HStack {
                        Text("搜索并发数")
                        Spacer()
                        Text("\(concurrency)")
                            .foregroundColor(.secondary)
                    }
                }

                HStack {
                    Text("当前")
                    Spacer()
                    Text("同时请求 \(concurrency) 个书源")
                        .foregroundColor(.secondary)
                }
                .font(.caption)
            } footer: {
                Text("并发越高越快，但更容易被站点限流或触发风控。书源多时建议 3~4；书源校验也用这个值。")
            }
        }
        .navigationTitle("搜索设置")
        .navigationBarTitleDisplayMode(.inline)
    }
}
