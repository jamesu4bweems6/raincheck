import CoreGraphics
import CoreImage
import Foundation
import SwiftUI

/// Thread-safe singleton QR renderer backed by a shared CIContext and NSCache.
private final class QrCodeRenderCache: @unchecked Sendable {
    static let shared = QrCodeRenderCache()

    private let lock = NSLock()
    private let context: CIContext
    private let cache: NSCache<NSString, CGImage>

    private init() {
        self.context = CIContext(options: [.useSoftwareRenderer: false])
        let imageCache = NSCache<NSString, CGImage>()
        imageCache.countLimit = 32
        self.cache = imageCache
    }

    func image(for content: String) -> CGImage? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let key = trimmed as NSString
        lock.lock()
        if let cached = cache.object(forKey: key) {
            lock.unlock()
            return cached
        }
        lock.unlock()

        guard let payload = trimmed.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else {
            return nil
        }

        filter.setValue(payload, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")

        guard let outputImage = filter.outputImage else { return nil }
        let baseExtent = outputImage.extent.integral
        let maxSide = max(baseExtent.width, baseExtent.height)
        guard maxSide > 0 else { return nil }

        let scale = max(1, floor(512.0 / maxSide))
        let scaledImage = outputImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let renderExtent = scaledImage.extent.integral

        guard let cgImage = context.createCGImage(scaledImage, from: renderExtent) else {
            return nil
        }

        lock.lock()
        cache.setObject(cgImage, forKey: key)
        lock.unlock()
        return cgImage
    }
}

/// Crisp monochrome QR code mounted on a pure white scan plate inside a neutral Liquid Glass frame.
struct QrCodePlateView: View {
    let content: String
    let size: CGFloat

    init(content: String, size: CGFloat = 216) {
        self.content = content
        self.size = size
    }

    var body: some View {
        let plateShape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        let cgImage = QrCodeRenderCache.shared.image(for: content)

        Group {
            if let cgImage {
                Image(cgImage, scale: 1.0, orientation: .up, label: Text("登录二维码"))
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size, height: size)
            } else {
                Image(systemName: "qrcode")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(LiquidPalette.tertiaryText)
                    .frame(width: size, height: size)
                    .accessibilityLabel("二维码暂不可用")
            }
        }
        .padding(14)
        .background(Color.white, in: plateShape)
        .padding(14)
        .liquidGlassCard(cornerRadius: LiquidMetrics.cornerRadiusCard)
    }
}
