import PencilKit
import SwiftUI
import UIKit

// MARK: - Lasso selection state

/// Holds stable source-record IDs in the current region and any bounded rendered visual crops.
struct LassoSelection {
    var selectedBlockIds: [UUID] = []
    /// PNG data for selected Pencil content or canvas-image previews.
    var drawingImagesByBlockId: [UUID: Data] = [:]

    var isEmpty: Bool { selectedBlockIds.isEmpty }
}

// MARK: - Block frame preference key

struct BlockFramePreferenceKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

struct BlockFrameAnchorPreferenceKey: PreferenceKey {
    static let defaultValue: [UUID: Anchor<CGRect>] = [:]
    static func reduce(
        value: inout [UUID: Anchor<CGRect>],
        nextValue: () -> [UUID: Anchor<CGRect>]
    ) {
        value.merge(nextValue()) { _, new in new }
    }
}

// MARK: - UIKit lasso gesture view

/// A transparent UIKit view that captures a pan gesture to draw a freehand lasso path.
/// Reports the bounding CGRect of the path on gesture end.
final class LassoGestureView: UIView {
    var onSelectionRect: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?

    private var path: UIBezierPath = .init()
    private var points: [CGPoint] = []
    private let shapeLayer = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        backgroundColor = .clear
        isUserInteractionEnabled = true

        shapeLayer.fillColor = UIColor.clear.cgColor
        shapeLayer.strokeColor = UIColor.label.withAlphaComponent(0.45).cgColor
        shapeLayer.lineWidth = 2.5
        shapeLayer.lineDashPattern = [8, 5]
        shapeLayer.lineJoin = .round
        shapeLayer.lineCap = .round
        layer.addSublayer(shapeLayer)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)

        // Allow dismissal via two-finger tap or dedicated cancel button in SwiftUI.
        accessibilityLabel = "Region selection mode. Draw a circle around notebook content to select it."
        accessibilityTraits = [.allowsDirectInteraction]
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        let location = recognizer.location(in: self)

        switch recognizer.state {
        case .began:
            points = [location]
            path = UIBezierPath()
            path.move(to: location)
        case .changed:
            points.append(location)
            path.addLine(to: location)
            shapeLayer.path = path.cgPath
        case .ended, .cancelled:
            // Close the path visually.
            if let first = points.first {
                path.addLine(to: first)
                shapeLayer.path = path.cgPath
            }
            if recognizer.state == .ended, points.count > 2 {
                let xs = points.map(\.x)
                let ys = points.map(\.y)
                let rect = CGRect(
                    x: xs.min()!,
                    y: ys.min()!,
                    width: xs.max()! - xs.min()!,
                    height: ys.max()! - ys.min()!
                )
                // Only report if the selection has meaningful area.
                if rect.width > 20 && rect.height > 20 {
                    onSelectionRect?(rect)
                } else {
                    reset()
                    onCancel?()
                }
            } else {
                reset()
                onCancel?()
            }
        default:
            break
        }
    }

    func reset() {
        points = []
        path = UIBezierPath()
        shapeLayer.path = nil
    }
}

// MARK: - SwiftUI wrapper

struct LassoOverlayView: UIViewRepresentable {
    @Binding var isActive: Bool
    var onSelectionRect: (CGRect) -> Void
    var onCancel: () -> Void

    func makeUIView(context: Context) -> LassoGestureView {
        let view = LassoGestureView()
        view.onSelectionRect = { rect in
            onSelectionRect(rect)
        }
        view.onCancel = {
            onCancel()
        }
        return view
    }

    func updateUIView(_ uiView: LassoGestureView, context: Context) {
        if !isActive {
            uiView.reset()
        }
    }
}

// MARK: - Drawing crop helper

/// Crop a PKDrawing to the portion that intersects `rect` (in canvas coordinates),
/// render it as a PNG, and return the Data. Returns nil if no strokes fall in rect.
func cropDrawing(_ drawing: PKDrawing, to rect: CGRect, scale: CGFloat = 2.0) -> Data? {
    // Filter strokes whose bounding boxes intersect the crop rect.
    let relevantStrokes = drawing.strokes.filter { stroke in
        stroke.renderBounds.intersects(rect)
    }
    guard !relevantStrokes.isEmpty else { return nil }

    let cropped = PKDrawing(strokes: relevantStrokes)
    let image = cropped.image(from: rect, scale: scale)

    // Reject empty images (fully transparent).
    guard let cgImage = image.cgImage, cgImage.width > 0, cgImage.height > 0 else {
        return nil
    }
    return image.pngData()
}
