@testable import Epistoria
import EpistoriaCore
import Testing
import UIKit

@MainActor
struct CanvasViewportFitTests {
    @Test func fitAllUsesContentBoundsAndReturnRestoresTheView() {
        let host = SpatialNotebookHostView(frame: CGRect(x: 0, y: 0, width: 900, height: 700))
        let items = [item(x: -600, y: -200), item(x: 400, y: 300)]
        apply(host, items: items, action: .fitContent)
        // UIScrollView rounds offsets to display pixels; compare the visible screen displacement.
        #expect(abs(host.viewportWorldCenterForTesting.x) * host.viewportZoomScaleForTesting <= 0.5)
        #expect(abs(host.viewportWorldCenterForTesting.y - 100) * host.viewportZoomScaleForTesting <= 0.5)
        #expect(abs(host.viewportZoomScaleForTesting - 0.71) < 0.001)
        let prior = NoteCanvasViewport(centerX: -300, centerY: 250, zoom: 1.5)
        apply(host, items: items, action: .restoreViewport(prior))
        #expect(abs(host.viewportWorldCenterForTesting.x + 300) < 0.01)
        #expect(abs(host.viewportZoomScaleForTesting - 1.5) < 0.001)
    }

    @Test func selectionExcludesOtherObjectsAndRespectsRotation() {
        let host = SpatialNotebookHostView(frame: CGRect(x: 0, y: 0, width: 900, height: 700))
        var selected = item(x: 200, y: 100)
        selected.placement.rotationRadians = .pi / 2
        apply(host, items: [selected, item(x: 9000, y: -9000)], selected: selected.id, action: .fitSelection)
        #expect(abs(host.viewportWorldCenterForTesting.x - 300) * host.viewportZoomScaleForTesting <= 0.5)
        #expect(abs(host.viewportWorldCenterForTesting.y - 150) * host.viewportZoomScaleForTesting <= 0.5)
        #expect(abs(host.viewportZoomScaleForTesting - 3.26) < 0.001)
    }

    @Test func emptyContentDoesNotMoveAndExtremeSpreadStaysWithinZoomLimits() {
        let host = SpatialNotebookHostView(frame: CGRect(x: 0, y: 0, width: 900, height: 700))
        apply(host, items: [], action: .fitContent)
        #expect(host.viewportZoomScaleForTesting == 1)
        apply(host, items: [item(x: -10000, y: 0), item(x: 10000, y: 0)], action: .fitContent)
        #expect(host.viewportZoomScaleForTesting == 0.25)
    }

    @Test func fittingWaitsForNonzeroLayout() {
        let host = SpatialNotebookHostView(frame: .zero)
        apply(host, items: [item(x: 200, y: 100)], action: .fitContent)
        host.frame = CGRect(x: 0, y: 0, width: 900, height: 700)
        host.setNeedsLayout()
        host.layoutIfNeeded()
        #expect(abs(host.viewportWorldCenterForTesting.x - 300) <= 0.5)
        #expect(abs(host.viewportWorldCenterForTesting.y - 150) <= 0.5)
        #expect(host.viewportZoomScaleForTesting == 4)
    }

    @Test func zoomLimitIsDisclosed() async {
        let host = SpatialNotebookHostView(frame: CGRect(x: 0, y: 0, width: 900, height: 700))
        let message = await withCheckedContinuation { continuation in
            host.onViewportNotice = { text in continuation.resume(returning: text) }
            apply(host, items: [item(x: -10000, y: 0), item(x: 10000, y: 0)], action: .fitContent)
        }
        #expect(message == "Minimum zoom reached. Some content remains outside the view.")
    }

    @Test func deferredFitCannotOverrideANewerReturnCommand() async {
        let host = SpatialNotebookHostView(frame: CGRect(x: 0, y: 0, width: 900, height: 700))
        host.defersViewportCallbacks = true
        let items = [item(x: 200, y: 100)]
        apply(host, items: items, action: .fitContent)
        let target = NoteCanvasViewport(centerX: -300, centerY: 250, zoom: 1.5)
        apply(host, items: items, action: .restoreViewport(target))
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(abs(host.viewportWorldCenterForTesting.x + 300) <= 0.5)
        #expect(abs(host.viewportWorldCenterForTesting.y - 250) <= 0.5)
        #expect(host.viewportZoomScaleForTesting == 1.5)
    }

    private func item(x: Double, y: Double) -> SpatialNotebookItem {
        SpatialNotebookItem(id: UUID(), placement: NoteCanvasPlacement(x: x, y: y, width: 200, height: 100),
                            content: .text(NSAttributedString(string: "Fixture")))
    }

    private func apply(_ host: SpatialNotebookHostView, items: [SpatialNotebookItem], selected: UUID? = nil,
                       action: SpatialNotebookCommand.Action) {
        host.apply(configuration: NoteCanvasConfiguration(pageFormat: .infinite), pageIndex: 0,
            items: items, inkData: Data(), inkBlockId: nil, mode: .select, inkTool: .pen,
            inkWidth: 4, inkColor: .black, eraserMode: .stroke, eraserWidth: 24,
            command: SpatialNotebookCommand(action: action), allowsViewportNavigation: true,
            selectedItemId: selected, lassoSelectedIds: [], focus: nil, editingItemId: nil, isReadOnly: false)
        host.setNeedsLayout()
        host.layoutIfNeeded()
    }
}
