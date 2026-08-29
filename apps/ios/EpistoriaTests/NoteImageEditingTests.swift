@testable import Epistoria
import EpistoriaCore
import UIKit
import XCTest

@MainActor
final class NoteImageEditingTests: XCTestCase {
    func testRendererAppliesQuarterTurnThenNormalizedCrop() throws {
        let image = fixtureImage(size: CGSize(width: 120, height: 80))
        let configuration = NoteCanvasImageConfiguration(
            crop: NoteCanvasImageCrop(x: 0.25, y: 0, width: 0.5, height: 1),
            rotationQuarterTurns: 1
        )

        let result = NoteCanvasImageRenderer.transformedImage(
            image,
            configuration: configuration,
            maximumDimension: 1_000
        )

        XCTAssertEqual(result.size.width, 40, accuracy: 0.01)
        XCTAssertEqual(result.size.height, 120, accuracy: 0.01)
    }

    func testEllipseMaskKeepsCenterAndClearsCorners() throws {
        let image = fixtureImage(size: CGSize(width: 100, height: 100))
        let result = NoteCanvasImageRenderer.transformedImage(
            image,
            configuration: NoteCanvasImageConfiguration(mask: .ellipse),
            maximumDimension: 1_000
        )
        let cgImage = try XCTUnwrap(result.cgImage)

        XCTAssertEqual(alpha(in: cgImage, x: 0, y: 0), 0)
        XCTAssertGreaterThan(alpha(in: cgImage, x: 50, y: 50), 240)
    }

    func testCropSanitizationFailsClosedToFiniteBounds() {
        let crop = NoteCanvasImageCrop(
            x: .infinity,
            y: -20,
            width: .nan,
            height: 80
        )

        XCTAssertEqual(crop.x, 0)
        XCTAssertEqual(crop.y, 0)
        XCTAssertEqual(crop.width, 1)
        XCTAssertEqual(crop.height, 1)
    }

    private func fixtureImage(size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    private func alpha(in image: CGImage, x: Int, y: Int) -> UInt8 {
        var bytes = [UInt8](repeating: 0, count: 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: &bytes,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(
            image,
            in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height)
        )
        return bytes[3]
    }
}
