import UIKit

/// A direct-manipulation handle over the selected object bounds, never over the whole page.
final class CanvasGroupMoveView: UIView {
    var onBegan: (() -> Void)?
    var onTranslation: ((CGPoint) -> Void)?
    var onEnded: ((CGPoint?) -> Void)?
    private(set) var isDragging = false
    private var touchOrigin: CGPoint?
    private lazy var pan = UIPanGestureRecognizer(target: self, action: #selector(drag(_:)))

    enum Direction: String, CaseIterable {
        case left, right, up, down
        var translation: CGPoint {
            switch self {
            case .left: CGPoint(x: -20, y: 0)
            case .right: CGPoint(x: 20, y: 0)
            case .up: CGPoint(x: 0, y: -20)
            case .down: CGPoint(x: 0, y: 20)
            }
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        layer.borderColor = UIColor.label.cgColor
        layer.borderWidth = 1.5
        layer.cornerRadius = 4
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)
        isAccessibilityElement = true
        accessibilityLabel = "Move selected objects"
        accessibilityIdentifier = "note.selection.move-handle"
        accessibilityHint = "Drag, or use actions to move the selection by 20 screen points."
        accessibilityCustomActions = Direction.allCases.map { direction in
            UIAccessibilityCustomAction(name: "Move \(direction.rawValue)") { [weak self] _ in
                self?.nudge(direction) ?? false
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @discardableResult
    func nudge(_ direction: Direction) -> Bool {
        guard !isHidden, isUserInteractionEnabled, !isDragging, onEnded != nil else { return false }
        beginDrag()
        finishDrag(direction.translation)
        return true
    }

    func beginDrag() {
        guard !isDragging else { return }
        isDragging = true
        onBegan?()
    }

    func finishDrag(_ translation: CGPoint?) {
        guard isDragging else { return }
        isDragging = false
        touchOrigin = nil
        if let translation { onTranslation?(translation) }
        onEnded?(translation)
    }

    func interrupt() {
        finishDrag(nil)
        touchOrigin = nil
        pan.isEnabled = false
        pan.isEnabled = true
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchOrigin = touches.first?.location(in: superview)
        super.touchesBegan(touches, with: event)
    }

    @objc private func drag(_ recognizer: UIPanGestureRecognizer) {
        let location = recognizer.location(in: superview)
        let translation = touchOrigin.map { CGPoint(x: location.x - $0.x, y: location.y - $0.y) }
            ?? recognizer.translation(in: superview)
        switch recognizer.state {
        case .began:
            beginDrag()
            onTranslation?(translation)
        case .changed:
            if isDragging { onTranslation?(translation) }
        case .ended:
            finishDrag(translation)
        case .cancelled, .failed:
            finishDrag(nil)
        default: break
        }
    }
}
