import Foundation

public struct CanvasAlignmentResult: Equatable, Sendable {
    public var placement: NoteCanvasPlacement
    public var verticalGuide: Double?
    public var horizontalGuide: Double?
}

public enum CanvasAlignment {
    public static func align(_ placement: NoteCanvasPlacement, to others: [NoteCanvasPlacement],
        pageWidth: Double? = nil, pageHeight: Double? = nil, tolerance: Double = 6
    ) -> CanvasAlignmentResult {
        func anchors(_ p: NoteCanvasPlacement) -> ([Double], [Double]) {
            let width = abs(cos(p.rotationRadians)) * p.width + abs(sin(p.rotationRadians)) * p.height
            let height = abs(sin(p.rotationRadians)) * p.width + abs(cos(p.rotationRadians)) * p.height
            let x = p.x + p.width / 2, y = p.y + p.height / 2
            return ([x - width / 2, x, x + width / 2], [y - height / 2, y, y + height / 2])
        }
        let source = anchors(placement)
        var xs: [Double] = pageWidth.map { width -> [Double] in [0, width / 2, width] } ?? []
        var ys: [Double] = pageHeight.map { height -> [Double] in [0, height / 2, height] } ?? []
        for other in others {
            let target = anchors(other)
            xs.append(contentsOf: target.0)
            ys.append(contentsOf: target.1)
        }
        func closest(_ values: [Double], _ targets: [Double]) -> (Double, Double)? {
            var best: (Double, Double)?
            for target in targets.sorted() where target.isFinite {
                for value in values where value.isFinite {
                    let delta = target - value
                    if abs(delta) <= tolerance, abs(delta) < abs(best?.0 ?? .infinity) {
                        best = (delta, target)
                    }
                }
            }
            return best
        }
        let x = closest(source.0, xs), y = closest(source.1, ys)
        var result = placement
        result.x += x?.0 ?? 0
        result.y += y?.0 ?? 0
        return CanvasAlignmentResult(placement: result, verticalGuide: x?.1, horizontalGuide: y?.1)
    }
}
