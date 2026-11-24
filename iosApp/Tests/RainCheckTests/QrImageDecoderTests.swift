import CoreGraphics
import CoreImage
import Foundation
import UIKit
import XCTest
@testable import RainCheck

final class QrImageDecoderTests: XCTestCase {
    private func makeQrPngData(
        for payload: String,
        scale: CGFloat = 10,
        quietZone: CGFloat = 32
    ) throws -> Data {
        let filter = try XCTUnwrap(CIFilter(name: "CIQRCodeGenerator"))
        filter.setValue(Data(payload.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")

        let rawOutput = try XCTUnwrap(filter.outputImage)
        let scaled = rawOutput.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let paddedExtent = scaled.extent.insetBy(dx: -quietZone, dy: -quietZone)
        let whiteBackground = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: paddedExtent)
        let composited = scaled.composited(over: whiteBackground)

        let context = CIContext()
        let cgImage = try XCTUnwrap(context.createCGImage(composited, from: paddedExtent))
        let uiImage = UIImage(cgImage: cgImage)
        return try XCTUnwrap(uiImage.pngData())
    }

    private func makeBlankPngData(size: CGSize = CGSize(width: 240, height: 240)) throws -> Data {
        let rect = CGRect(origin: .zero, size: size)
        let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: rect)
        let context = CIContext()
        let cgImage = try XCTUnwrap(context.createCGImage(white, from: rect))
        let uiImage = UIImage(cgImage: cgImage)
        return try XCTUnwrap(uiImage.pngData())
    }

    func testDecodeValidQrPngSynchronouslyAndAsynchronously() async throws {
        let expectedPayload = "https://www.yuketang.cn/v2/web/checkin?lessonId=9988&c=abc123&t=1700000000&s=sig"
        let pngData = try makeQrPngData(for: expectedPayload)
        XCTAssertFalse(pngData.isEmpty)

        let syncDecoded = QrImageDecoder.decode(from: pngData)
        XCTAssertEqual(syncDecoded, expectedPayload)

        let asyncDecoded = await QrImageDecoder.decodeAsync(from: pngData)
        XCTAssertEqual(asyncDecoded, expectedPayload)

        let profile = try TestBundleResources.loadProtocolProfile()
        let ticket = QrCodeParser.parse(try XCTUnwrap(syncDecoded), profile: profile)
        XCTAssertEqual(ticket.kind, .dynamicCheckin)
        XCTAssertEqual(ticket.host, "www.yuketang.cn")
        XCTAssertEqual(ticket.lessonId, "9988")
        XCTAssertEqual(ticket.dynamicCode, "abc123")
        XCTAssertEqual(ticket.timestamp, "1700000000")
        XCTAssertEqual(ticket.signature, "sig")
    }

    func testDecodeReturnsNilOnEmptyBlankAndInvalidData() async throws {
        XCTAssertNil(QrImageDecoder.decode(from: Data()))
        let asyncEmpty = await QrImageDecoder.decodeAsync(from: Data())
        XCTAssertNil(asyncEmpty)

        let invalidData = Data("not-a-valid-image-payload".utf8)
        XCTAssertNil(QrImageDecoder.decode(from: invalidData))
        let asyncInvalid = await QrImageDecoder.decodeAsync(from: invalidData)
        XCTAssertNil(asyncInvalid)

        let blankPng = try makeBlankPngData()
        XCTAssertNil(QrImageDecoder.decode(from: blankPng))
        let asyncBlank = await QrImageDecoder.decodeAsync(from: blankPng)
        XCTAssertNil(asyncBlank)
    }
}
