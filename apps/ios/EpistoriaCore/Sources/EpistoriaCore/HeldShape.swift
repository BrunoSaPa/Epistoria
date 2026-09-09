import Foundation

/// Conservative single-stroke geometry. No OCR, provider or notebook mutation.
public struct HeldShape: Equatable, Sendable {
    public enum Kind: String, Sendable { case line, circle, ellipse, rectangle }
    public let kind: Kind
    public let points: [CGPoint]

    public static func recognize(_ points: [CGPoint]) -> HeldShape? {
        guard (4...2048).contains(points.count),
              points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
              let first = points.first, let last = points.last else { return nil }
        func distance(_ a: CGPoint, _ b: CGPoint) -> Double { hypot(a.x - b.x, a.y - b.y) }
        let length = zip(points, points.dropFirst()).reduce(0) { $0 + distance($1.0, $1.1) }
        guard length.isFinite, length <= 32_768 else { return nil }
        let chord = distance(first, last)
        if chord >= 30, length < chord * 1.12 {
            let deviations = points.map { abs((last.x - first.x) * ($0.y - first.y)
                - (last.y - first.y) * ($0.x - first.x)) / chord }
            if deviations.max() ?? .infinity <= max(2, chord * 0.035) {
                return HeldShape(kind: .line, points: [first, last])
            }
        }
        let xs = points.map(\.x), ys = points.map(\.y)
        let x0 = xs.min()!, x1 = xs.max()!, y0 = ys.min()!, y1 = ys.max()!
        let width = x1 - x0, height = y1 - y0
        guard width >= 24, height >= 24, chord < min(width, height) * 0.28 else { return nil }
        let cx = (x0 + x1) / 2, cy = (y0 + y1) / 2
        let normalized = points.map { CGPoint(x: ($0.x - cx) / (width / 2), y: ($0.y - cy) / (height / 2)) }
        // Closed writing and scribbles must not qualify solely because their bounds are round.
        let perimeter = 2 * Double.pi * sqrt((width * width + height * height) / 8)
        let radialError = normalized.reduce(0) { $0 + abs(hypot($1.x, $1.y) - 1) } / Double(points.count)
        if radialError < 0.1, length > perimeter * 0.8, length < perimeter * 1.25 {
            let circular = abs(width - height) / max(width, height) < 0.12
            let radiusX = circular ? (width + height) / 4 : width / 2
            let radiusY = circular ? radiusX : height / 2
            return HeldShape(kind: circular ? .circle : .ellipse, points: (0...96).map { index in
                let angle = Double(index) * 2 * .pi / 96
                return CGPoint(x: cx + cos(angle) * radiusX, y: cy + sin(angle) * radiusY)
            })
        }
        let edgeError = normalized.reduce(0) { $0 + min(abs(abs($1.x) - 1), abs(abs($1.y) - 1)) } / Double(points.count)
        let corners = [CGPoint(x: x0, y: y0), CGPoint(x: x1, y: y0), CGPoint(x: x1, y: y1), CGPoint(x: x0, y: y1)]
        let touchesCorners = corners.allSatisfy { corner in points.contains { distance($0, corner) < min(width, height) * 0.2 } }
        if edgeError < 0.09, touchesCorners, length > (width + height) * 1.7, length < (width + height) * 2.5 {
            return HeldShape(kind: .rectangle, points: corners + [corners[0]])
        }
        return nil
    }
}
