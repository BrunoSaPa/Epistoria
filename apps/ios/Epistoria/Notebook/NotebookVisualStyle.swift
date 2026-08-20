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

struct NotebookModifierPreview<Content: View>: View {
    let name: String
    let value: String
    private let content: Content

    init(
        name: String,
        value: String,
        @ViewBuilder content: () -> Content
    ) {
        self.name = name
        self.value = value
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text("Preview")
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 8)
                Text(value)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(EpistoriaDesign.mutedInk)
                    .lineLimit(1)
            }
            content
                .frame(maxWidth: .infinity)
                .frame(height: 72)
                .background(
                    Color(uiColor: .secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: EpistoriaDesign.compactRadius)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: EpistoriaDesign.compactRadius)
                        .stroke(EpistoriaDesign.border, lineWidth: 0.5)
                }
                .clipShape(RoundedRectangle(cornerRadius: EpistoriaDesign.compactRadius))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name) preview")
        .accessibilityValue(value)
    }
}

struct NotebookInkPreview: View {
    let color: NoteCanvasColor
    let width: CGFloat
    let isMarker: Bool

    var body: some View {
        Canvas { context, size in
            var path = Path()
            path.move(to: CGPoint(x: 22, y: size.height * 0.58))
            path.addCurve(
                to: CGPoint(x: size.width - 22, y: size.height * 0.43),
                control1: CGPoint(x: size.width * 0.30, y: size.height * 0.18),
                control2: CGPoint(x: size.width * 0.67, y: size.height * 0.82)
            )
            context.stroke(
                path,
                with: .color(Color(uiColor: color.uiColor).opacity(isMarker ? 0.32 : 1)),
                style: StrokeStyle(
                    lineWidth: width,
                    lineCap: .round,
                    lineJoin: .round
                )
            )
        }
    }
}

struct NotebookEraserPreview: View {
    let mode: SpatialNotebookEraserMode
    let width: CGFloat

    var body: some View {
        Canvas { context, size in
            let ink = Color(uiColor: .label)
            let fadedInk = Color(uiColor: .secondaryLabel)
            let paper = Color(uiColor: .secondarySystemBackground)

            for index in 0 ..< 3 {
                let y = size.height * (0.28 + CGFloat(index) * 0.22)
                var stroke = Path()
                stroke.move(to: CGPoint(x: 18, y: y))
                stroke.addCurve(
                    to: CGPoint(x: size.width - 18, y: y + (index == 1 ? -3 : 3)),
                    control1: CGPoint(x: size.width * 0.32, y: y - 8),
                    control2: CGPoint(x: size.width * 0.68, y: y + 8)
                )
                let isRemovedStroke = mode == .stroke && index == 1
                context.stroke(
                    stroke,
                    with: .color(isRemovedStroke ? fadedInk.opacity(0.28) : ink),
                    style: StrokeStyle(
                        lineWidth: 3,
                        lineCap: .round,
                        dash: isRemovedStroke ? [5, 5] : []
                    )
                )
            }

            if mode == .pixel {
                let diameter = min(max(width, 8), 56)
                let footprint = CGRect(
                    x: size.width / 2 - diameter / 2,
                    y: size.height / 2 - diameter / 2,
                    width: diameter,
                    height: diameter
                )
                context.fill(Path(ellipseIn: footprint), with: .color(paper))
                context.stroke(
                    Path(ellipseIn: footprint),
                    with: .color(fadedInk),
                    style: StrokeStyle(lineWidth: 1, dash: [3, 3])
                )
            } else {
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                var removalMark = Path()
                removalMark.move(to: CGPoint(x: center.x - 7, y: center.y - 7))
                removalMark.addLine(to: CGPoint(x: center.x + 7, y: center.y + 7))
                removalMark.move(to: CGPoint(x: center.x + 7, y: center.y - 7))
                removalMark.addLine(to: CGPoint(x: center.x - 7, y: center.y + 7))
                context.stroke(
                    removalMark,
                    with: .color(fadedInk),
                    style: StrokeStyle(lineWidth: 1.5, lineCap: .round)
                )
            }
        }
    }
}

struct NotebookShapePreview: View {
    let shape: NoteCanvasShape

    var body: some View {
        Canvas { context, size in
            let lineWidth = CGFloat(shape.lineWidth)
            let bounds = CGRect(
                x: 42,
                y: 13,
                width: max(size.width - 84, 1),
                height: max(size.height - 26, 1)
            )
            let path = Path(
                NotebookShapePath.make(
                    kind: shape.kind,
                    in: bounds,
                    lineWidth: lineWidth
                )
            )
            if let fillColor = shape.fillColor {
                context.fill(
                    path,
                    with: .color(Color(uiColor: fillColor.uiColor).opacity(0.18))
                )
            }
            context.stroke(
                path,
                with: .color(Color(uiColor: shape.strokeColor.uiColor)),
                style: StrokeStyle(
                    lineWidth: lineWidth,
                    lineCap: .round,
                    lineJoin: .round
                )
            )
        }
    }
}
