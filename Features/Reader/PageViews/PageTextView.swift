//
//  PageTextView.swift
//  Legado-iOS
//
//  正文渲染：直接用 CoreText 绘制
//  与 PageSplitter 使用同一份 NSAttributedString，保证「分页边界」和「屏幕显示」完全一致，
//  同时支持字距、首行缩进、行高倍数、两端对齐这些 SwiftUI Text 做不到的排版项。
//

import SwiftUI
import UIKit
import CoreText

// MARK: - UIKit 绘制层

final class CoreTextPageUIView: UIView {
    private var attributed: NSAttributedString?
    private var insets: UIEdgeInsets = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(text: String, config: PageConfig) {
        let attributed = PageSplitter.attributedText(text: text, config: config)
        insets = config.margins
        if self.attributed != attributed {
            self.attributed = attributed
            setNeedsDisplay()
        }
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(), let attributed else { return }

        let area = CGRect(
            x: insets.left,
            y: insets.bottom,
            width: bounds.width - insets.left - insets.right,
            height: bounds.height - insets.top - insets.bottom
        )
        guard area.width > 0, area.height > 0 else { return }

        context.saveGState()
        context.textMatrix = .identity
        let path = CGPath(rect: area, transform: nil)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let frame = CTFramesetterCreateFrame(framesetter, CFRangeMake(0, 0), path, nil)
        CTFrameDraw(frame, context)
        context.restoreGState()
    }
}

// MARK: - SwiftUI 包装

struct PageTextView: View {
    let text: String
    @ObservedObject var viewModel: ReaderViewModel

    var body: some View {
        GeometryReader { geometry in
            CoreTextPageRepresentable(
                text: text,
                config: viewModel.makePageConfig(containerSize: geometry.size),
                textColor: UIColor(viewModel.textColor)
            )
        }
    }
}

// MARK: - 图片章节（CBZ 漫画）

struct ImageChapterScrollView: View {
    let images: [URL]

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(images, id: \.self) { url in
                    if let image = UIImage(contentsOfFile: url.path) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity)
                    } else {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.gray.opacity(0.15))
                            .frame(height: 180)
                            .overlay(Text("图片读取失败").font(.caption).foregroundColor(.secondary))
                            .padding(8)
                    }
                }
            }
        }
    }
}

private struct CoreTextPageRepresentable: UIViewRepresentable {
    let text: String
    let config: PageConfig
    let textColor: UIColor

    func makeUIView(context: Context) -> CoreTextPageUIView {
        CoreTextPageUIView()
    }

    func updateUIView(_ uiView: CoreTextPageUIView, context: Context) {
        var config = config
        config.textColor = textColor
        uiView.configure(text: text, config: config)
    }
}
