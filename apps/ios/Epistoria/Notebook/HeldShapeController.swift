import EpistoriaCore
import PencilKit
import UIKit

@MainActor
final class HeldShapeController {
    private weak var canvas: PKCanvasView?
    private let recognizer = HoldShapeGestureRecognizer()
    private let preview = CAShapeLayer()
    private let actions = UIStackView()
    private var candidate: HeldShape?
    private var beforeStroke = PKDrawing()
    private var reviewedDrawing: PKDrawing?
    private var finished = false
    private var enabled = false

    init(canvas: PKCanvasView, container: UIView) {
        self.canvas = canvas
        recognizer.cancelsTouchesInView = false
        recognizer.delaysTouchesBegan = false
        recognizer.delaysTouchesEnded = false
        recognizer.isEnabled = false
        canvas.addGestureRecognizer(recognizer)
        preview.fillColor = UIColor.clear.cgColor
        preview.strokeColor = UIColor.label.cgColor
        preview.lineWidth = 2
        preview.lineDashPattern = [5, 4]
        preview.zPosition = 100_000
        canvas.layer.addSublayer(preview)

        actions.axis = .vertical
        actions.spacing = 4
        actions.backgroundColor = .systemBackground
        actions.tintColor = .label
        actions.layer.cornerRadius = 8
        actions.layer.borderWidth = 1
        actions.layer.borderColor = UIColor.separator.cgColor
        actions.isLayoutMarginsRelativeArrangement = true
        actions.layoutMargins = UIEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        actions.translatesAutoresizingMaskIntoConstraints = false
        for (title, accept) in [("Use shape", true), ("Keep ink", false)] {
            let button = UIButton(type: .system)
            button.setTitle(title, for: .normal)
            button.titleLabel?.font = .preferredFont(forTextStyle: .body)
            button.titleLabel?.adjustsFontForContentSizeCategory = true
            button.addAction(UIAction { [weak self] _ in
                if accept { self?.accept() } else { self?.clear() }
            }, for: .touchUpInside)
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            actions.addArrangedSubview(button)
        }
        container.addSubview(actions)
        NSLayoutConstraint.activate([
            actions.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor, constant: 8),
            actions.trailingAnchor.constraint(equalTo: container.safeAreaLayoutGuide.trailingAnchor, constant: -12),
        ])
        actions.isHidden = true
        recognizer.onBegin = { [weak self] in
            guard let self, let canvas = self.canvas else { return }
            self.clear(); self.beforeStroke = canvas.drawing
        }
        recognizer.onPreview = { [weak self] shape in self?.show(shape) }
        recognizer.onFinish = { [weak self] held in
            guard let self else { return }
            self.finished = held
            if !held { self.clear(); return }
            // PencilKit commits the final stroke at the end of this input event.
            Task { @MainActor [weak self] in
                await Task.yield()
                self?.drawingChanged()
            }
        }
    }

    func setEnabled(_ value: Bool) {
        guard enabled != value else { return }
        enabled = value
        recognizer.isEnabled = value
        if !value { clear() }
    }

    func clear() {
        candidate = nil; reviewedDrawing = nil; finished = false
        actions.isHidden = true
        CATransaction.begin(); CATransaction.setDisableActions(true)
        preview.path = nil
        CATransaction.commit()
    }

    func interrupt() {
        recognizer.isEnabled = false
        recognizer.isEnabled = enabled
        clear()
    }

    #if DEBUG
    func proposeForTesting(_ shape: HeldShape, before: PKDrawing) {
        beforeStroke = before; finished = true; show(shape); drawingChanged()
    }
    var isReviewVisibleForTesting: Bool { !actions.isHidden }
    func acceptForTesting() { accept() }
    #endif

    func drawingChanged() {
        guard finished, candidate != nil, let canvas else { return }
        if let reviewedDrawing, canvas.drawing != reviewedDrawing { clear(); return }
        guard canvas.drawing.strokes.count == beforeStroke.strokes.count + 1,
              zip(canvas.drawing.strokes.dropLast(), beforeStroke.strokes).allSatisfy({ Self.sameStroke($0, $1) }) else {
            return
        }
        reviewedDrawing = canvas.drawing
        let wasHidden = actions.isHidden
        actions.isHidden = false
        actions.superview?.bringSubviewToFront(actions)
        if wasHidden { UIAccessibility.post(notification: .layoutChanged, argument: actions.arrangedSubviews.first) }
    }

    private func show(_ shape: HeldShape?) {
        candidate = shape
        actions.arrangedSubviews.first?.accessibilityLabel = shape.map { "Use \($0.kind.rawValue)" } ?? "Use shape"
        let path = UIBezierPath()
        if let points = shape?.points, let first = points.first {
            path.move(to: first)
            for point in points.dropFirst() { path.addLine(to: point) }
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        preview.frame = canvas?.bounds ?? .zero
        preview.path = path.cgPath
        CATransaction.commit()
    }

    private func accept() {
        guard enabled, finished, let canvas, let shape = candidate,
              let original = reviewedDrawing, canvas.drawing == original,
              let last = original.strokes.last, !last.path.isEmpty else { clear(); return }
        let sample = last.path[last.path.count / 2]
        // Retain the original ink style and use dense points for straight B-spline segments.
        var locations: [CGPoint] = []
        for (a, b) in zip(shape.points, shape.points.dropFirst()) {
            if shape.kind == .rectangle { locations += [a, a, a] }
            let count = max(1, Int(ceil(hypot(b.x - a.x, b.y - a.y) / 4)))
            for index in 0..<count {
                let t = Double(index) / Double(count)
                locations.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            }
        }
        locations += Array(repeating: shape.points.last!, count: 3)
        let points = locations.enumerated().map { index, point in
            PKStrokePoint(location: point, timeOffset: Double(index) / 120,
                size: sample.size, opacity: sample.opacity, force: sample.force,
                azimuth: sample.azimuth, altitude: sample.altitude)
        }
        let stroke = PKStroke(ink: last.ink, path: PKStrokePath(controlPoints: points, creationDate: .now))
        clear()
        replace(PKDrawing(strokes: Array(original.strokes.dropLast()) + [stroke]))
    }

    private func replace(_ drawing: PKDrawing) {
        guard let canvas else { return }
        let old = canvas.drawing
        canvas.undoManager?.registerUndo(withTarget: self) { target in target.replace(old) }
        canvas.undoManager?.setActionName("Straighten shape")
        canvas.drawing = drawing
        canvas.delegate?.canvasViewDrawingDidChange?(canvas)
    }

    // New PKDrawing(strokes:) instances have different drawing identities even when their ink
    // is identical. Compare the authoritative stroke data, not newly constructed drawing IDs.
    static func sameStroke(_ lhs: PKStroke, _ rhs: PKStroke) -> Bool {
        guard lhs.ink.inkType == rhs.ink.inkType, lhs.ink.color == rhs.ink.color,
              lhs.transform == rhs.transform, lhs.mask?.cgPath == rhs.mask?.cgPath,
              lhs.randomSeed == rhs.randomSeed, lhs.path.creationDate == rhs.path.creationDate,
              lhs.path.count == rhs.path.count else { return false }
        return zip(lhs.path, rhs.path).allSatisfy { a, b in
            a.location == b.location && a.timeOffset == b.timeOffset && a.size == b.size
                && a.opacity == b.opacity && a.force == b.force
                && a.azimuth == b.azimuth && a.altitude == b.altitude
        }
    }
}
