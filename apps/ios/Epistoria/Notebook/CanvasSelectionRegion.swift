import UIKit

enum CanvasSelectionShape: String, CaseIterable {
    case freehand = "Freehand"
    case rectangle = "Rectangle"

    func boundary(start: CGPoint, current: CGPoint, samples: [CGPoint]) -> [CGPoint] {
        switch self {
        case .freehand: samples
        case .rectangle:
            [start, CGPoint(x: current.x, y: start.y), current, CGPoint(x: start.x, y: current.y)]
        }
    }
}

enum CanvasSelectionContent: String, CaseIterable {
    case ink = "Ink", text = "Text", images = "Images", shapes = "Shapes", evidence = "Evidence", other = "Other objects"

    init(_ content: SpatialNotebookItem.Content) {
        switch content {
        case .legacyDrawing: self = .ink
        case .text: self = .text
        case .image: self = .images
        case .shape: self = .shapes
        case .evidence: self = .evidence
        case .unsupported: self = .other
        }
    }
}

struct CanvasSelectionOptions: Equatable {
    var shape: CanvasSelectionShape = .freehand
    var content = Set(CanvasSelectionContent.allCases)
}

/// The actual selection boundary, not just its enclosing rectangle.
struct CanvasSelectionRegion {
    let points: [CGPoint]

    var path: CGPath {
        let path = CGMutablePath()
        if let first = points.first {
            path.move(to: first)
            for point in points.dropFirst() { path.addLine(to: point) }
            path.closeSubpath()
        }
        return path
    }
    var bounds: CGRect { path.boundingBoxOfPath }
    var isValid: Bool {
        points.count >= 3 && points.allSatisfy { $0.x.isFinite && $0.y.isFinite }
            && bounds.width > 0 && bounds.height > 0
    }

    func contains(_ point: CGPoint) -> Bool { path.contains(point, using: .evenOdd) }

    func intersects(_ polygon: [CGPoint]) -> Bool {
        guard !polygon.isEmpty else { return false }
        if polygon.contains(where: contains) { return true }
        let other = CanvasSelectionRegion(points: polygon)
        if let first = points.first, other.contains(first) { return true }
        return intersectsLine(polygon + [polygon[0]])
    }

    func intersectsLine(_ line: [CGPoint]) -> Bool {
        let boundary = path
        if line.contains(where: { boundary.contains($0, using: .evenOdd) }) { return true }
        guard line.count > 1, points.count > 2 else { return false }
        for index in 1..<line.count {
            for edge in points.indices {
                if Self.crosses(line[index - 1], line[index], points[edge], points[(edge + 1) % points.count]) { return true }
            }
        }
        return false
    }

    private static func crosses(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint) -> Bool {
        func cross(_ p: CGPoint, _ q: CGPoint, _ r: CGPoint) -> CGFloat {
            (q.x - p.x) * (r.y - p.y) - (q.y - p.y) * (r.x - p.x)
        }
        func onSegment(_ p: CGPoint, _ q: CGPoint, _ r: CGPoint) -> Bool {
            r.x >= min(p.x, q.x) && r.x <= max(p.x, q.x)
                && r.y >= min(p.y, q.y) && r.y <= max(p.y, q.y)
        }
        let abC = cross(a, b, c), abD = cross(a, b, d), cdA = cross(c, d, a), cdB = cross(c, d, b)
        if abC == 0 && onSegment(a, b, c) { return true }
        if abD == 0 && onSegment(a, b, d) { return true }
        if cdA == 0 && onSegment(c, d, a) { return true }
        if cdB == 0 && onSegment(c, d, b) { return true }
        return (abC > 0) != (abD > 0) && (cdA > 0) != (cdB > 0)
    }
}
