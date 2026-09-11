@testable import Epistoria
import Testing
import UIKit

@MainActor
struct CanvasSelectionRegionTests {
    let region = CanvasSelectionRegion(points: [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 0, y: 100)])

    @Test(arguments: [CGPoint(x: 100, y: 100), CGPoint(x: -100, y: 100), CGPoint(x: -100, y: -100), CGPoint(x: 100, y: -100)])
    func rectangleSelectionWorksInEveryDragDirection(end: CGPoint) {
        let points = CanvasSelectionShape.rectangle.boundary(start: .zero, current: end, samples: [])
        let rectangle = CanvasSelectionRegion(points: points)
        #expect(points.count == 4)
        #expect(rectangle.isValid)
        #expect(rectangle.bounds.width == 100 && rectangle.bounds.height == 100)
        #expect(rectangle.contains(CGPoint(x: end.x / 2, y: end.y / 2)))
    }

    @Test func defaultsIncludeEveryContentTypeAndFreehandRetainsSamples() {
        let options = CanvasSelectionOptions()
        #expect(options.content == Set(CanvasSelectionContent.allCases))
        #expect(options.shape == .freehand)
        #expect(options.shape.boundary(start: .zero, current: CGPoint(x: 0, y: 100), samples: region.points) == region.points)
    }

    @Test func lassoDoesNotSelectBoundingBoxCornersOutsideTheLoop() {
        #expect(region.isValid)
        #expect(region.contains(CGPoint(x: 10, y: 10)))
        #expect(!region.contains(CGPoint(x: 90, y: 90)))
        #expect(!region.intersects([CGPoint(x: 80, y: 80), CGPoint(x: 90, y: 80), CGPoint(x: 90, y: 90), CGPoint(x: 80, y: 90)]))
        #expect(region.intersectsLine([CGPoint(x: -10, y: 20), CGPoint(x: 120, y: 20)]))
        #expect(!region.intersectsLine([CGPoint(x: 80, y: 80), CGPoint(x: 90, y: 90)]))
        #expect(region.intersects([CGPoint(x: -20, y: -20), CGPoint(x: 120, y: -20), CGPoint(x: 120, y: 120), CGPoint(x: -20, y: 120)]))
    }

    @Test func visualCropMasksPixelsOutsideTheActualBoundary() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let original = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 100), format: format).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        }
        let png = try #require(original.pngData())
        let masked = try #require(maskSelectionPNG(png, region: region, cropRect: CGRect(x: 0, y: 0, width: 100, height: 100)))
        let image = try #require(UIImage(data: masked)?.cgImage)
        var pixels = [UInt8](repeating: 0, count: 100 * 100 * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try #require(CGContext(data: bytes.baseAddress, width: 100, height: 100,
                bitsPerComponent: 8, bytesPerRow: 400, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: 100, height: 100))
        }
        let transparent = stride(from: 3, to: pixels.count, by: 4).filter { pixels[$0] == 0 }.count
        #expect(transparent > 4_000 && transparent < 6_000)
        #expect(original.pngData() == png)
    }
}
