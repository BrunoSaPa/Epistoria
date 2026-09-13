@testable import Epistoria
import Testing
import UIKit

@MainActor
struct CanvasGroupMoveViewTests {
    @Test(arguments: ["background", "window removal", "resize"])
    func hostInterruptionsCannotCommitALateDrag(event: String) throws {
        let host = SpatialNotebookHostView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        host.layoutIfNeeded()
        let handle = try #require(host.subviews.compactMap { $0 as? CanvasGroupMoveView }.first)
        var commits = 0
        host.onGroupMove = { _ in commits += 1 }
        handle.beginDrag()
        switch event {
        case "background":
            NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
        case "window removal":
            host.willMove(toWindow: nil)
        default:
            host.frame.size = CGSize(width: 600, height: 800)
            host.setNeedsLayout()
            host.layoutIfNeeded()
        }
        #expect(!handle.isDragging)
        handle.finishDrag(CGPoint(x: 40, y: 30))
        #expect(commits == 0)
    }

    @Test func interruptionCancelsOnceAndIgnoresLateRelease() {
        let view = CanvasGroupMoveView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        var cancellations = 0
        var commits = 0
        view.onEnded = { delta in
            if delta == nil { cancellations += 1 } else { commits += 1 }
        }
        view.beginDrag()
        view.interrupt()
        view.interrupt()
        view.finishDrag(CGPoint(x: 40, y: 30))
        #expect(!view.isDragging)
        #expect(cancellations == 1)
        #expect(commits == 0)
        view.beginDrag()
        view.finishDrag(CGPoint(x: 40, y: 30))
        #expect(commits == 1)
    }

    @Test(arguments: CanvasGroupMoveView.Direction.allCases)
    func accessibleMovementUsesTheSameCommitPath(direction: CanvasGroupMoveView.Direction) {
        let view = CanvasGroupMoveView(frame: .zero)
        var events: [String] = []
        var result: CGPoint?
        view.onBegan = { events.append("begin") }
        view.onTranslation = { _ in events.append("preview") }
        view.onEnded = { delta in events.append("end"); result = delta }
        #expect(view.nudge(direction))
        #expect(events == ["begin", "preview", "end"])
        #expect(result == direction.translation)
        #expect(view.accessibilityCustomActions?.count == 4)
        view.isUserInteractionEnabled = false
        #expect(!view.nudge(direction))
        view.isUserInteractionEnabled = true
        view.isHidden = true
        #expect(!view.nudge(direction))
        #expect(events.count == 3)
    }
}
