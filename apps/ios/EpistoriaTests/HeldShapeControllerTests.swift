@testable import Epistoria
import EpistoriaCore
import PencilKit
import UIKit
import XCTest

@MainActor
final class HeldShapeControllerTests: XCTestCase {
    private func stroke(_ offset: CGFloat = 0) -> PKStroke {
        let points = (0...30).map { index in
            PKStrokePoint(location: CGPoint(x: 20 + CGFloat(index) * 3, y: 40 + offset + sin(Double(index)) * 0.5),
                timeOffset: Double(index) / 120, size: CGSize(width: 3, height: 3),
                opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: points, creationDate: .now))
    }

    func testPreviewKeepInkAndStaleDrawingDoNotReplaceOriginal() throws {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 500, height: 500))
        let canvas = PKCanvasView(frame: container.bounds)
        container.addSubview(canvas)
        let controller = HeldShapeController(canvas: canvas, container: container)
        controller.setEnabled(true)
        let original = PKDrawing(strokes: [stroke()])
        canvas.drawing = original
        let shape = try XCTUnwrap(HeldShape.recognize((0...30).map { CGPoint(x: 20 + $0 * 3, y: 40) }))
        controller.proposeForTesting(shape, before: PKDrawing())
        XCTAssertTrue(controller.isReviewVisibleForTesting)
        XCTAssertEqual(canvas.drawing, original)
        controller.clear()
        XCTAssertEqual(canvas.drawing, original)
        controller.proposeForTesting(shape, before: PKDrawing())
        let newer = PKDrawing(strokes: [stroke(), stroke(30)])
        canvas.drawing = newer
        controller.acceptForTesting()
        XCTAssertEqual(canvas.drawing, newer)
        XCTAssertFalse(controller.isReviewVisibleForTesting)
    }

    func testAcceptPreservesEarlierStrokesAndUndoRestoresOriginal() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 500, height: 500))
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let container = try XCTUnwrap(window.rootViewController?.view)
        let canvas = PKCanvasView(frame: container.bounds)
        container.addSubview(canvas)
        canvas.becomeFirstResponder()
        let controller = HeldShapeController(canvas: canvas, container: container)
        controller.setEnabled(true)
        let preceding = stroke(80)
        let before = PKDrawing(strokes: [preceding])
        let original = PKDrawing(strokes: [preceding, stroke()])
        canvas.drawing = original
        let undo = try XCTUnwrap(canvas.undoManager)
        undo.removeAllActions()
        let shape = try XCTUnwrap(HeldShape.recognize((0...30).map { CGPoint(x: 20 + $0 * 3, y: 40) }))
        controller.proposeForTesting(shape, before: before)
        undo.beginUndoGrouping()
        controller.acceptForTesting()
        undo.endUndoGrouping()
        XCTAssertNotEqual(canvas.drawing, original)
        XCTAssertEqual(canvas.drawing.strokes.count, 2)
        XCTAssertTrue(HeldShapeController.sameStroke(canvas.drawing.strokes[0], preceding))
        undo.undo()
        XCTAssertEqual(canvas.drawing, original)
        undo.redo()
        XCTAssertNotEqual(canvas.drawing, original)
    }
}
