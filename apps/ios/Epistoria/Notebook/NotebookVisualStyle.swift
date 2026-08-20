import EpistoriaCore
import SwiftUI
import UIKit

extension NotePaperColor {
    var label: String {
        switch self {
        case .white: "White"
        case .ivory: "Ivory"
        case .fog: "Fog"
        case .stone: "Stone"
        }
    }

    var uiColor: UIColor {
        switch self {
        case .white: UIColor(white: 1, alpha: 1)
        case .ivory: UIColor(red: 0.98, green: 0.97, blue: 0.93, alpha: 1)
        case .fog: UIColor(white: 0.92, alpha: 1)
        case .stone: UIColor(white: 0.82, alpha: 1)
        }
    }

    var lineColor: UIColor {
        UIColor.black.withAlphaComponent(self == .stone ? 0.22 : 0.16)
    }

    var swiftUIColor: Color { Color(uiColor: uiColor) }
}

extension NoteCanvasColor {
    var label: String {
        switch self {
        case .black: "Black"
        case .graphite: "Graphite"
        case .red: "Red"
        case .blue: "Blue"
        case .green: "Green"
        case .white: "White"
        }
    }

    var uiColor: UIColor {
        switch self {
        case .black: .black
        case .graphite: UIColor(white: 0.35, alpha: 1)
        case .red: .systemRed
        case .blue: .systemBlue
        case .green: .systemGreen
        case .white: .white
        }
    }
}

extension NoteCanvasShapeKind {
    var label: String {
        switch self {
        case .rectangle: "Rectangle"
        case .roundedRectangle: "Rounded"
        case .ellipse: "Ellipse"
        case .triangle: "Triangle"
        case .diamond: "Diamond"
        case .line: "Line"
        case .arrow: "Arrow"
        }
    }

    var systemImage: String {
        switch self {
        case .rectangle: "rectangle"
        case .roundedRectangle: "rectangle.roundedtop"
        case .ellipse: "circle"
        case .triangle: "triangle"
        case .diamond: "diamond"
        case .line: "line.diagonal"
        case .arrow: "arrow.right"
        }
    }
}

enum NotebookShapePath {
    static func make(kind: NoteCanvasShapeKind, in rect: CGRect, lineWidth: CGFloat) -> CGPath {
        let inset = max(lineWidth / 2, 1)
        let bounds = rect.insetBy(dx: inset, dy: inset)
        let path = UIBezierPath()
        switch kind {
        case .rectangle:
            return UIBezierPath(rect: bounds).cgPath
        case .roundedRectangle:
            return UIBezierPath(
                roundedRect: bounds,
                cornerRadius: min(bounds.width, bounds.height) * 0.12
            ).cgPath
        case .ellipse:
            return UIBezierPath(ovalIn: bounds).cgPath
        case .triangle:
            path.move(to: CGPoint(x: bounds.midX, y: bounds.minY))
            path.addLine(to: CGPoint(x: bounds.maxX, y: bounds.maxY))
            path.addLine(to: CGPoint(x: bounds.minX, y: bounds.maxY))
            path.close()
        case .diamond:
            path.move(to: CGPoint(x: bounds.midX, y: bounds.minY))
            path.addLine(to: CGPoint(x: bounds.maxX, y: bounds.midY))
            path.addLine(to: CGPoint(x: bounds.midX, y: bounds.maxY))
            path.addLine(to: CGPoint(x: bounds.minX, y: bounds.midY))
            path.close()
        case .line:
            path.move(to: CGPoint(x: bounds.minX, y: bounds.maxY))
            path.addLine(to: CGPoint(x: bounds.maxX, y: bounds.minY))
        case .arrow:
            let head = min(bounds.width * 0.24, bounds.height * 0.44)
            path.move(to: CGPoint(x: bounds.minX, y: bounds.midY))
            path.addLine(to: CGPoint(x: bounds.maxX, y: bounds.midY))
            path.move(to: CGPoint(x: bounds.maxX - head, y: bounds.midY - head))
            path.addLine(to: CGPoint(x: bounds.maxX, y: bounds.midY))
            path.addLine(to: CGPoint(x: bounds.maxX - head, y: bounds.midY + head))
        }
        return path.cgPath
    }
}
