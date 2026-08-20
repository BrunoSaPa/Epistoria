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

    func testChangingFinitePageResetsToReachablePageGeometry() {
        let host = SpatialNotebookHostView(
            frame: CGRect(x: 0, y: 0, width: 1_024, height: 768)
        )
        let configuration = NoteCanvasConfiguration(pageFormat: .a4, pageCount: 2)
        apply(to: host, configuration: configuration, pageIndex: 0)
        host.setNeedsLayout()
        host.layoutIfNeeded()

        apply(to: host, configuration: configuration, pageIndex: 1)

        XCTAssertEqual(host.displayedPageIndexForTesting, 1)
        XCTAssertTrue(host.viewportZoomScaleForTesting.isFinite)
        XCTAssertGreaterThan(host.viewportZoomScaleForTesting, 0)
        XCTAssertEqual(host.viewportWorldCenterForTesting.x, 297.5, accuracy: 1)
        XCTAssertEqual(host.viewportWorldCenterForTesting.y, 421, accuracy: 1)
    }

    func testEmbeddedPageUsesCustomToolAndLeavesNavigationToOuterScroll() {
        let host = SpatialNotebookHostView(
            frame: CGRect(x: 0, y: 0, width: 768, height: 1_024)
        )

        apply(
            to: host,
            configuration: NoteCanvasConfiguration(pageFormat: .a4, pageCount: 3),
            mode: .ink,
            inkTool: .eraser,
            allowsViewportNavigation: false
        )
        host.setNeedsLayout()
        host.layoutIfNeeded()

        XCTAssertFalse(host.allowsViewportNavigationForTesting)
        XCTAssertTrue(host.usesVectorEraserForTesting)
        XCTAssertEqual(host.eraserTypeForTesting, .vector)
        XCTAssertEqual(host.viewportZoomScaleForTesting, CGFloat(1_024) / 842, accuracy: 0.001)

        host.frame = CGRect(x: 0, y: 0, width: 512, height: 724)
        host.setNeedsLayout()
        host.layoutIfNeeded()

        XCTAssertEqual(host.viewportZoomScaleForTesting, CGFloat(512) / 595, accuracy: 0.001)
    }

    func testPixelEraserUsesFixedCircularWidth() {
        let host = SpatialNotebookHostView(
            frame: CGRect(x: 0, y: 0, width: 768, height: 1_024)
        )

        apply(
            to: host,
            configuration: NoteCanvasConfiguration(),
            mode: .ink,
            inkTool: .eraser,
            eraserMode: .pixel,
            eraserWidth: 38
        )

        XCTAssertEqual(host.eraserTypeForTesting, .fixedWidthBitmap)
        XCTAssertEqual(host.eraserWidthForTesting ?? -1, 38, accuracy: 0.001)
    }

    func testPaperInkAndShapeModifiersReachTheCanvas() {
        let host = SpatialNotebookHostView(
            frame: CGRect(x: 0, y: 0, width: 768, height: 1_024)
        )
        let shape = SpatialNotebookItem(
            id: UUID(),
            placement: NoteCanvasPlacement(x: 80, y: 120, width: 180, height: 140),
            content: .shape(
                NoteCanvasShape(
                    kind: .triangle,
                    strokeColor: .blue,
                    fillColor: .graphite,
                    lineWidth: 5
                )
            )
        )
        let configuration = NoteCanvasConfiguration(
            paperStyle: .isometric,
            paperColor: .stone,
            paperSpacing: 18
        )

        apply(
            to: host,
            configuration: configuration,
            items: [shape],
            mode: .ink,
            inkTool: .pen,
            inkColor: .blue
        )

        XCTAssertEqual(host.paperColorForTesting, .stone)
        XCTAssertEqual(host.paperSpacingForTesting, 18, accuracy: 0.001)
        let traits = UITraitCollection(userInterfaceStyle: .light)
        let expectedInk = NoteCanvasColor.blue.uiColor.resolvedColor(with: traits)
        let actualInk = try? XCTUnwrap(host.inkColorForTesting).resolvedColor(with: traits)
        var expectedComponents = (red: CGFloat.zero, green: CGFloat.zero, blue: CGFloat.zero, alpha: CGFloat.zero)
        var actualComponents = (red: CGFloat.zero, green: CGFloat.zero, blue: CGFloat.zero, alpha: CGFloat.zero)
        XCTAssertTrue(expectedInk.getRed(
            &expectedComponents.red,
            green: &expectedComponents.green,
            blue: &expectedComponents.blue,
            alpha: &expectedComponents.alpha
        ))
        XCTAssertTrue(actualInk?.getRed(
            &actualComponents.red,
            green: &actualComponents.green,
            blue: &actualComponents.blue,
            alpha: &actualComponents.alpha
        ) == true)
        XCTAssertEqual(actualComponents.red, expectedComponents.red, accuracy: 0.01)
        XCTAssertEqual(actualComponents.green, expectedComponents.green, accuracy: 0.01)
        XCTAssertEqual(actualComponents.blue, expectedComponents.blue, accuracy: 0.01)
        XCTAssertEqual(actualComponents.alpha, expectedComponents.alpha, accuracy: 0.01)
        XCTAssertEqual(host.renderedShapeCountForTesting, 1)
    }

    func testContinuousDocumentSelectsPageNearestViewportMidpoint() {
        let frames = [
            0: CGRect(x: 0, y: -700, width: 700, height: 990),
            1: CGRect(x: 0, y: 314, width: 700, height: 990),
            2: CGRect(x: 0, y: 1_328, width: 700, height: 990),
        ]

        XCTAssertEqual(
            ContinuousNotebookPageSelection.nearestPage(in: frames, viewportHeight: 1_024),
            1
        )
    }

    private func apply(
        to host: SpatialNotebookHostView,
        configuration: NoteCanvasConfiguration,
        pageIndex: Int = 0,
        items: [SpatialNotebookItem] = [],
        focus: SpatialNotebookFocus? = nil,
        mode: SpatialNotebookMode = .select,
        inkTool: SpatialNotebookInkTool = .pen,
        inkColor: NoteCanvasColor = .black,
        eraserMode: SpatialNotebookEraserMode = .stroke,
        eraserWidth: CGFloat = 24,
        allowsViewportNavigation: Bool = true
    ) {
        host.apply(
            configuration: configuration,
            pageIndex: pageIndex,
            items: items,
            inkData: Data(),
            inkBlockId: nil,
            mode: mode,
            inkTool: inkTool,
            inkWidth: 4,
            inkColor: inkColor,
            eraserMode: eraserMode,
            eraserWidth: eraserWidth,
            command: nil,
            allowsViewportNavigation: allowsViewportNavigation,
            selectedItemId: nil,
            lassoSelectedIds: [],
            focus: focus,
            editingItemId: nil,
            isReadOnly: false
        )
    }
}
