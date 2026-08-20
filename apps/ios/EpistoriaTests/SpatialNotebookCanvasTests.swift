@testable import Epistoria
import EpistoriaCore
import XCTest

@MainActor
final class SpatialNotebookCanvasTests: XCTestCase {
    func testSimulatorAcceptsPointerInkForDevelopment() {
        let host = SpatialNotebookHostView(frame: CGRect(x: 0, y: 0, width: 1_024, height: 768))

        #if targetEnvironment(simulator)
        XCTAssertTrue(host.acceptsAnyInkInputForTesting)
        #else
        XCTAssertFalse(host.acceptsAnyInkInputForTesting)
        #endif
    }

    func testTiledPaperDrawCanRunOffTheMainExecutor() async {
        struct UncheckedBox<Value>: @unchecked Sendable {
            let value: Value
        }

        let paper = NotebookPaperView(frame: CGRect(x: 0, y: 0, width: 512, height: 512))
        paper.paperStyle = .grid
        let paperBox = UncheckedBox(value: paper)

        await Task.detached {
            paperBox.value.draw(CGRect(x: 0, y: 0, width: 256, height: 256))
        }.value
    }

    func testZeroSizedHostDefersFocusUntilViewportIsUsable() {
        let blockID = UUID()
        let item = SpatialNotebookItem(
            id: blockID,
            placement: NoteCanvasPlacement(x: 360, y: 460, width: 180, height: 120),
            content: .text(NSAttributedString(string: "Focused evidence"))
        )
        let host = SpatialNotebookHostView(frame: .zero)

        apply(
            to: host,
            configuration: NoteCanvasConfiguration(),
            items: [item],
            focus: SpatialNotebookFocus(blockId: blockID, highlightedText: "evidence")
        )

        XCTAssertTrue(host.hasPendingFocusForTesting)
        host.frame = CGRect(x: 0, y: 0, width: 1_024, height: 768)
        host.setNeedsLayout()
        host.layoutIfNeeded()

        XCTAssertFalse(host.hasPendingFocusForTesting)
        XCTAssertTrue(host.viewportZoomScaleForTesting.isFinite)
        XCTAssertGreaterThan(host.viewportZoomScaleForTesting, 0)
    }

    func testInitialLayoutUsesPositiveZoomForEveryPageFormat() {
        for pageFormat in NotePageFormat.allCases {
            let host = SpatialNotebookHostView(frame: .zero)
            apply(
                to: host,
                configuration: NoteCanvasConfiguration(pageFormat: pageFormat)
            )

            host.frame = CGRect(x: 0, y: 0, width: 1_366, height: 1_024)
            host.setNeedsLayout()
            host.layoutIfNeeded()

            XCTAssertTrue(host.viewportZoomScaleForTesting.isFinite, "\(pageFormat)")
            XCTAssertGreaterThan(host.viewportZoomScaleForTesting, 0, "\(pageFormat)")
            XCTAssertGreaterThanOrEqual(host.viewportZoomScaleForTesting, 0.25, "\(pageFormat)")
            XCTAssertLessThanOrEqual(host.viewportZoomScaleForTesting, 4, "\(pageFormat)")
        }
    }

    func testFocusingAnItemCentersWithoutChangingZoom() {
        let blockID = UUID()
        let item = SpatialNotebookItem(
            id: blockID,
            placement: NoteCanvasPlacement(x: 420, y: 520, width: 180, height: 120),
            content: .text(NSAttributedString(string: "Study note"))
        )
        let host = SpatialNotebookHostView(
            frame: CGRect(x: 0, y: 0, width: 1_024, height: 768)
        )
        apply(to: host, configuration: NoteCanvasConfiguration(), items: [item])
        host.setNeedsLayout()
        host.layoutIfNeeded()
        let initialScale = host.viewportZoomScaleForTesting

        apply(
            to: host,
            configuration: NoteCanvasConfiguration(),
            items: [item],
            focus: SpatialNotebookFocus(blockId: blockID, highlightedText: nil)
        )

        XCTAssertEqual(host.viewportZoomScaleForTesting, initialScale, accuracy: 0.000_1)
        XCTAssertTrue(host.viewportWorldCenterForTesting.x.isFinite)
        XCTAssertTrue(host.viewportWorldCenterForTesting.y.isFinite)
    }

    private func apply(
        to host: SpatialNotebookHostView,
        configuration: NoteCanvasConfiguration,
        items: [SpatialNotebookItem] = [],
        focus: SpatialNotebookFocus? = nil
    ) {
        host.apply(
            configuration: configuration,
            items: items,
            inkData: Data(),
            inkBlockId: nil,
            mode: .select,
            selectedItemId: nil,
            lassoSelectedIds: [],
            focus: focus,
            editingItemId: nil,
            isReadOnly: false
        )
    }
}
