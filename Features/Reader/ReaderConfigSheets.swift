//
//  ReaderConfigSheets.swift
//  Legado-iOS
//
//  阅读器配置弹窗集合 - 参考 Android config 目录
//  包含背景色、文字样式、信息栏配置等
//

import SwiftUI

// MARK: - 背景色配置

struct BgTextConfigSheet: View {
    @Binding var isPresented: Bool
    @ObservedObject var viewModel: ReaderViewModel
    
    @AppStorage("readerBgColorIndex") private var bgColorIndex: Int = 0
    @AppStorage("readerTextColor") private var textColorHex: String = "#000000"
    
    // 预设背景色
    let bgPresets: [(name: String, color: Color, hex: String)] = [
        ("默认白", .white, "#FFFFFF"),
        ("护眼黄", Color(red: 1.0, green: 0.96, blue: 0.88), "#FFF5E0"),
        ("护眼绿", Color(red: 0.85, green: 0.95, blue: 0.85), "#D9F2D9"),
        ("淡蓝", Color(red: 0.9, green: 0.95, blue: 1.0), "#E6F2FF"),
        ("夜间黑", Color(red: 0.15, green: 0.15, blue: 0.15), "#262626"),
        ("深灰", Color(red: 0.2, green: 0.2, blue: 0.2), "#333333")
    ]
    
    var body: some View {
        NavigationView {
            List {
                Section("预设背景") {
                    ForEach(0..<bgPresets.count, id: \.self) { index in
                        Button {
                            bgColorIndex = index
                            viewModel.backgroundColor = bgPresets[index].color
                        } label: {
                            HStack {
                                Circle()
                                    .fill(bgPresets[index].color)
                                    .frame(width: 28, height: 28)
                                    .overlay(
                                        Circle()
                                            .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                                    )
                                
                                Text(bgPresets[index].name)
                                    .foregroundColor(.primary)
                                
                                Spacer()
                                
                                if bgColorIndex == index {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.blue)
                                }
                            }
                        }
                    }
                }
                
                Section("文字颜色") {
                    HStack {
                        Text("文字色")
                        Spacer()
                        
                        ForEach(["#000000", "#333333", "#666666", "#FFFFFF"], id: \.self) { hex in
                            Button {
                                textColorHex = hex
                                viewModel.textColor = Color(hex: hex) ?? .primary
                            } label: {
                                Circle()
                                    .fill(Color(hex: hex) ?? .primary)
                                    .frame(width: 24, height: 24)
                                    .overlay(
                                        Circle()
                                            .stroke(textColorHex == hex ? Color.blue : Color.clear, lineWidth: 2)
                                    )
                            }
                        }
                    }
                }
                
                Section {
                    Button("恢复默认") {
                        bgColorIndex = 0
                        textColorHex = "#000000"
                        viewModel.backgroundColor = .white
                        viewModel.textColor = .primary
                    }
                }
            }
            .navigationTitle("背景与文字")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") {
                        isPresented = false
                    }
                }
            }
        }
    }
}

// MARK: - 阅读样式配置

struct ReadStyleSheet: View {
    @Binding var isPresented: Bool
    @ObservedObject var viewModel: ReaderViewModel
    
    @AppStorage("readerFontSize") private var fontSize: Double = 18
    @AppStorage("readerLineSpacing") private var lineSpacing: Double = 8
    @AppStorage("readerParagraphSpacing") private var paragraphSpacing: Double = 12
    @AppStorage("readerLetterSpacing") private var letterSpacing: Double = 0
    @AppStorage("readerFirstLineIndent") private var firstLineIndent: Double = 2
    @AppStorage("readerLineHeightMultiple") private var lineHeightMultiple: Double = 1.15
    @AppStorage("readerJustified") private var justified: Bool = false
    
    var body: some View {
        NavigationView {
            List {
                Section("字体大小") {
                    HStack {
                        Text("字号")
                            .frame(width: 60, alignment: .leading)
                        
                        Slider(value: $fontSize, in: 12...36, step: 1)
                            .onChange(of: fontSize) { _ in
                                viewModel.fontSize = fontSize
                            }
                        
                        Text("\(Int(fontSize))")
                            .frame(width: 30)
                    }
                    
                    // 预设字号按钮
                    HStack {
                        FontSizePresetButton(title: "小", size: 14, current: $fontSize, viewModel: viewModel)
                        FontSizePresetButton(title: "中", size: 18, current: $fontSize, viewModel: viewModel)
                        FontSizePresetButton(title: "大", size: 22, current: $fontSize, viewModel: viewModel)
                        FontSizePresetButton(title: "特大", size: 28, current: $fontSize, viewModel: viewModel)
                    }
                }
                
                Section("间距") {
                    HStack {
                        Text("行间距")
                            .frame(width: 80, alignment: .leading)
                        Slider(value: $lineSpacing, in: 0...24, step: 2)
                        Text("\(Int(lineSpacing))")
                            .frame(width: 30)
                    }
                    .onChange(of: lineSpacing) { _ in
                        viewModel.lineSpacing = lineSpacing
                    }
                    
                    HStack {
                        Text("段落间距")
                            .frame(width: 80, alignment: .leading)
                        Slider(value: $paragraphSpacing, in: 0...32, step: 2)
                        Text("\(Int(paragraphSpacing))")
                            .frame(width: 30)
                    }
                    .onChange(of: paragraphSpacing) { _ in
                        viewModel.paragraphSpacing = paragraphSpacing
                    }
                    
                    HStack {
                        Text("字间距")
                            .frame(width: 80, alignment: .leading)
                        Slider(value: $letterSpacing, in: -2...4, step: 0.5)
                        Text("\(letterSpacing, specifier: "%.1f")")
                            .frame(width: 30)
                    }
                    .onChange(of: letterSpacing) { _ in
                        viewModel.letterSpacing = letterSpacing
                    }
                }

                Section("排版精度") {
                    HStack {
                        Text("首行缩进")
                            .frame(width: 80, alignment: .leading)
                        Slider(value: $firstLineIndent, in: 0...4, step: 0.5)
                        Text("\(firstLineIndent, specifier: "%.1f") 字")
                            .font(.caption)
                            .frame(width: 46, alignment: .trailing)
                    }
                    .onChange(of: firstLineIndent) { _ in
                        viewModel.firstLineIndentChars = firstLineIndent
                    }

                    HStack {
                        Text("行高倍数")
                            .frame(width: 80, alignment: .leading)
                        Slider(value: $lineHeightMultiple, in: 0.8...2.0, step: 0.05)
                        Text("\(lineHeightMultiple, specifier: "%.2f")")
                            .font(.caption)
                            .frame(width: 46, alignment: .trailing)
                    }
                    .onChange(of: lineHeightMultiple) { _ in
                        viewModel.lineHeightMultiple = lineHeightMultiple
                    }

                    Toggle("两端对齐", isOn: $justified)
                        .onChange(of: justified) { _ in
                            viewModel.textJustified = justified
                        }

                    Text("首行缩进、字距、行高倍数与两端对齐均按 CoreText 排版，分页结果与屏幕显示严格一致。")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                
                Section {
                    Button("恢复默认") {
                        fontSize = 18
                        lineSpacing = 8
                        paragraphSpacing = 12
                        letterSpacing = 0
                        viewModel.fontSize = 18
                        viewModel.lineSpacing = 8
                        viewModel.paragraphSpacing = 12
                        viewModel.letterSpacing = 0
                        firstLineIndent = 2
                        lineHeightMultiple = 1.15
                        justified = false
                        viewModel.firstLineIndentChars = 2
                        viewModel.lineHeightMultiple = 1.15
                        viewModel.textJustified = false
                    }
                }
            }
            .navigationTitle("阅读样式")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                // 与 ViewModel 当前值对齐（ViewModel 从 UserDefaults 的 reader.* 键恢复）
                firstLineIndent = Double(viewModel.firstLineIndentChars)
                lineHeightMultiple = Double(viewModel.lineHeightMultiple)
                justified = viewModel.textJustified
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") {
                        isPresented = false
                    }
                }
            }
        }
    }
}

private struct FontSizePresetButton: View {
    let title: String
    let size: Double
    @Binding var current: Double
    @ObservedObject var viewModel: ReaderViewModel
    
    var body: some View {
        Button(title) {
            current = size
            viewModel.fontSize = size
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(abs(current - size) < 1 ? Color.blue : Color(.systemGray5))
        .foregroundColor(abs(current - size) < 1 ? .white : .primary)
        .cornerRadius(6)
    }
}

// MARK: - 信息栏配置

struct TipConfigSheet: View {
    @Binding var isPresented: Bool
    
    @AppStorage("tipShowBattery") private var showBattery: Bool = true
    @AppStorage("tipShowTime") private var showTime: Bool = true
    @AppStorage("tipShowPageNumber") private var showPageNumber: Bool = true
    @AppStorage("tipShowChapterName") private var showChapterName: Bool = true
    @AppStorage("tipShowProgress") private var showProgress: Bool = true
    
    var body: some View {
        NavigationView {
            List {
                Section("顶部栏") {
                    Toggle("显示书名", isOn: .constant(true))
                        .disabled(true)
                    Toggle("显示章节名", isOn: $showChapterName)
                    Toggle("显示时间", isOn: $showTime)
                    Toggle("显示电量", isOn: $showBattery)
                }
                
                Section("底部栏") {
                    Toggle("显示页码", isOn: $showPageNumber)
                    Toggle("显示进度百分比", isOn: $showProgress)
                }
                
                Section {
                    Button("恢复默认") {
                        showBattery = true
                        showTime = true
                        showPageNumber = true
                        showChapterName = true
                        showProgress = true
                    }
                }
            }
            .navigationTitle("信息栏设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") {
                        isPresented = false
                    }
                }
            }
        }
    }
}

// MARK: - Color Hex 扩展

extension Color {
    init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")
        
        guard hexSanitized.count == 6 else { return nil }
        
        var rgb: UInt64 = 0
        guard Scanner(string: hexSanitized).scanHexInt64(&rgb) else { return nil }
        
        self.init(
            red: Double((rgb & 0xFF0000) >> 16) / 255.0,
            green: Double((rgb & 0x00FF00) >> 8) / 255.0,
            blue: Double(rgb & 0x0000FF) / 255.0
        )
    }
}