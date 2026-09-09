import EpistoriaCore
import UIKit

/// Observes alongside PencilKit without claiming or cancelling its stroke gesture.
@MainActor
final class HoldShapeGestureRecognizer: UIGestureRecognizer {
    var onBegin: (() -> Void)?
    var onPreview: ((HeldShape?) -> Void)?
    var onFinish: ((Bool) -> Void)?
    private var points: [CGPoint] = []
    private var anchor = CGPoint.zero
    private var timer: Task<Void, Never>?
    private var touch: UITouch?
    private var previewed = false

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard touch == nil, touches.count == 1, let input = touches.first else { cancel(); return }
        #if !targetEnvironment(simulator)
        guard input.type == .pencil else { state = .failed; return }
        #endif
        touch = input
        points = [input.location(in: view)]
        anchor = input.location(in: nil)
        onBegin?()
        armTimer()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch, touches.contains(touch) else { return }
        let point = touch.location(in: view)
        if let last = points.last, hypot(point.x - last.x, point.y - last.y) >= 1 { points.append(point) }
        guard points.count <= 2048 else { cancel(); return }
        let screen = touch.location(in: nil)
        if hypot(screen.x - anchor.x, screen.y - anchor.y) > 4 {
            anchor = screen; previewed = false; onPreview?(nil); armTimer()
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        timer?.cancel()
        onFinish?(previewed)
        state = .failed // Observer never wins against the drawing recognizer.
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { cancel() }
    override func reset() {
        timer?.cancel(); timer = nil; touch = nil; points = []; previewed = false
        super.reset()
    }

    private func cancel() {
        timer?.cancel(); onPreview?(nil); onFinish?(false); state = .failed
    }

    private func armTimer() {
        timer?.cancel()
        timer = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(650)) } catch { return }
            guard let self, !Task.isCancelled, self.touch != nil,
                  let shape = HeldShape.recognize(self.points) else { return }
            self.previewed = true
            self.onPreview?(shape)
        }
    }
}
