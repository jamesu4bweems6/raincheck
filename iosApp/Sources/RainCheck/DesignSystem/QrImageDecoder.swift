import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UIKit
import Vision

/// Decodes QR code payloads from photo library image data using Vision first and CoreImage as fallback.
enum QrImageDecoder: Sendable {
    /// Decodes the first non-empty QR payload off the main actor.
    static func decodeAsync(from imageData: Data) async -> String? {
        await Task.detached(priority: .userInitiated) {
            decode(from: imageData)
        }.value
    }

    /// Synchronously decodes a QR payload from raw image bytes (JPEG, PNG, HEIC, etc.).
    static func decode(from imageData: Data) -> String? {
        guard !imageData.isEmpty else { return nil }

        let orientation = exifOrientation(from: imageData)

        if let visionPayload = decodeWithVision(data: imageData, orientation: orientation) {
            return visionPayload
        }

        return decodeWithCoreImage(data: imageData, orientation: orientation)
    }

    private static func decodeWithVision(
        data: Data,
        orientation: CGImagePropertyOrientation
    ) -> String? {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]

        let handler = VNImageRequestHandler(
            data: data,
            orientation: orientation,
            options: [:]
        )

        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        guard let observations = request.results, !observations.isEmpty else {
            return nil
        }

        let candidates = observations
            .filter { $0.symbology == .qr }
            .sorted { $0.confidence > $1.confidence }

        for observation in candidates {
            if let payload = normalizedPayload(observation.payloadStringValue) {
                return payload
            }
        }

        return nil
    }

    private static func decodeWithCoreImage(
        data: Data,
        orientation: CGImagePropertyOrientation
    ) -> String? {
        guard let detector = CIDetector(
            ofType: CIDetectorTypeQRCode,
            context: nil,
            options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
        ) else {
            return nil
        }

        let image: CIImage?
        if let direct = CIImage(data: data, options: [.applyOrientationProperty: true]) {
            image = direct
        } else if let uiImage = UIImage(data: data) {
            if let cgImage = uiImage.cgImage {
                image = CIImage(cgImage: cgImage).oriented(orientation)
            } else {
                image = CIImage(image: uiImage)?.oriented(orientation)
            }
        } else {
            image = nil
        }

        guard let ciImage = image else { return nil }

        let features = detector.features(in: ciImage)
        for case let qrFeature as CIQRCodeFeature in features {
            if let payload = normalizedPayload(qrFeature.messageString) {
                return payload
            }
        }

        return nil
    }

    private static func exifOrientation(from data: Data) -> CGImagePropertyOrientation {
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let rawValue = (properties[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value,
           let orientation = CGImagePropertyOrientation(rawValue: rawValue) {
            return orientation
        }

        if let image = UIImage(data: data) {
            return cgImagePropertyOrientation(from: image.imageOrientation)
        }

        return .up
    }

    private static func cgImagePropertyOrientation(
        from orientation: UIImage.Orientation
    ) -> CGImagePropertyOrientation {
        switch orientation {
        case .up: return .up
        case .upMirrored: return .upMirrored
        case .down: return .down
        case .downMirrored: return .downMirrored
        case .left: return .left
        case .leftMirrored: return .leftMirrored
        case .right: return .right
        case .rightMirrored: return .rightMirrored
        @unknown default: return .up
        }
    }

    private static func normalizedPayload(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
