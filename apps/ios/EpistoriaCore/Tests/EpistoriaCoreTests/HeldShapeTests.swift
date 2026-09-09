import Foundation
import Testing
@testable import EpistoriaCore

struct HeldShapeTests {
    @Test func recognizesLinesAtDifferentAngles() {
        for end in [CGPoint(x: 100, y: 0), CGPoint(x: 0, y: 120), CGPoint(x: -90, y: 90)] {
            let points = (0...40).map { CGPoint(x: end.x * Double($0) / 40, y: end.y * Double($0) / 40) }
            #expect(HeldShape.recognize(points)?.kind == .line)
        }
    }

    @Test func recognizesClosedEllipseAndRectangle() {
        let ellipse = (0...120).map { index in
            let angle = Double(index) * 2 * Double.pi / 120
            return CGPoint(x: 60 + cos(angle) * 60, y: 40 + sin(angle) * 40)
        }
        #expect(HeldShape.recognize(ellipse)?.kind == .ellipse)
        let circle = ellipse.map { CGPoint(x: $0.x, y: $0.y * 1.5) }
        #expect(HeldShape.recognize(circle)?.kind == .circle)
        let corners = [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 60), CGPoint(x: 0, y: 60), .zero]
        var rectangle: [CGPoint] = []
        for (a, b) in zip(corners, corners.dropFirst()) {
            for index in 0..<25 {
                let t = Double(index) / 25
                rectangle.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            }
        }
        rectangle.append(.zero)
        #expect(HeldShape.recognize(rectangle)?.kind == .rectangle)
    }

    @Test func rejectsSmallWritingBacktrackingInvalidAndExcessInput() {
        #expect(HeldShape.recognize([.zero, CGPoint(x: 3, y: 1), CGPoint(x: 6, y: 0), CGPoint(x: 9, y: 1)]) == nil)
        #expect(HeldShape.recognize([.zero, CGPoint(x: 100, y: 0), .zero, CGPoint(x: 100, y: 0)]) == nil)
        #expect(HeldShape.recognize(Array(repeating: CGPoint(x: Double.nan, y: 0), count: 20)) == nil)
        #expect(HeldShape.recognize(Array(repeating: .zero, count: 2049)) == nil)
    }
}
