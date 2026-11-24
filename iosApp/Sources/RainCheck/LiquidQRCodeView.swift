//
//  LiquidQRCodeView.swift
//  RainCheck
//
//  缓存式 CoreImage 二维码渲染器：
//   - 共享单例 `CIContext` + `NSCache` 缓存生成的 `CGImage`；
//   - 绝不在 SwiftUI `body` 重绘时重建 `CIContext` 或重复执行 `CIFilter`。
//

import SwiftUI
import CoreImage
import CoreGraphics

private final class CachedCGImageBox: @unchecked Sendable {
    let cgImage: CGImage
    init(_ cgImage: CGImage) {
        self.cgImage = cgImage
    }
}

/// 线程安全的二维码渲染器与 `CGImage` 内存缓存。
final class LiquidQRCodeRenderer: @unchecked Sendable {
    static let shared = LiquidQRCodeRenderer()

    private let context: CIContext
    private let cache: NSCache<NSString, CachedCGImageBox>

    private init() {
        self.context = CIContext(options: [.cacheIntermediates: false])
        let imageCache = NSCache<NSString, CachedCGImageBox>()
        imageCache.countLimit = 24
        self.cache = imageCache
    }

    /// 生成或从缓存命中二维码 `CGImage`。
    func cachedCGImage(for content: String, pixelSize: CGFloat) -> CGImage? {
        let text = content.trimmed
        guard !text.isEmpty else { return nil }
        let side = max(Int(pixelSize.rounded()), 64)
        let cacheKey = "\(side)::\(text)" as NSString
        if let hit = cache.object(forKey: cacheKey) {
            return hit.cgImage
        }
        guard let rendered = renderCGImage(text: text, side: CGFloat(side)) else {
            return nil
        }
        cache.setObject(CachedCGImageBox(rendered), forKey: cacheKey)
        return rendered
    }

    private func renderCGImage(text: String, side: CGFloat) -> CGImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else {
            return nil
        }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else {
            return nil
        }
        let extent = output.extent
        guard !extent.isEmpty, !extent.isInfinite else {
            return nil
        }
        let scale = max(1.0, (side / max(extent.width, 1.0)).rounded(.down))
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return context.createCGImage(scaled, from: scaled.extent)
    }
}

/// 液态玻璃边框承载的缓存二维码视图。
struct LiquidQRCodeView: View {
    let content: String
    var size: CGFloat

    @Environment(\.displayScale) private var displayScale
    @State private var renderedCGImage: CGImage?

    init(content: String, size: CGFloat = 228) {
        self.content = content
        self.size = size
    }

    private var renderKey: String {
        "\(Int((size * displayScale).rounded()))::\(content)"
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.white)

            if let renderedCGImage {
                Image(decorative: renderedCGImage, scale: 1.0, orientation: .up)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .padding(14)
            } else {
                ProgressView()
                    .tint(.secondary)
            }
        }
        .frame(width: size, height: size)
        .shadow(color: Color.black.opacity(0.14), radius: 14, x: 0, y: 6)
        .padding(10)
        .liquidGlassCard(cornerRadius: 28, variant: .regular, tint: LiquidPalette.sapphire)
        .task(id: renderKey) {
            let pixelSize = max(size * max(displayScale, 2.0), 256)
            let snapshot = content
            let cgImage = await Task.detached(priority: .userInitiated) {
                LiquidQRCodeRenderer.shared.cachedCGImage(for: snapshot, pixelSize: pixelSize)
            }.value
            guard !Task.isCancelled else { return }
            renderedCGImage = cgImage
        }
    }
}
